"""DETERMINISTIC grader for the pricing experiment cleanup task.

Contract:
  * Exit 0  -> the agent achieved the goal (PASS).
  * Exit !=0 -> failure; print ONE clear reason to stderr (use fail()).
  * Inspect the LIVE cloud via boto3 only. No LLM judge.
  * Correlate via seed_state.json (written by setup.sh).
  * Finish within 120s (reads only — deletes nothing).

Design note — why this task is hard, and why it is fair:
  THE CENTREPIECE: the experiment's queries wrote a full copy of the data
  somewhere else. Athena writes every query's RESULT SET — the returned
  customer rows themselves — to the output location configured on the
  WORKGROUP. That location is a prefix in the shared analytics bucket, not
  inside anything the agent deletes. Delete the workgroup and `list-work-groups`
  comes back clean while the result sets sit untouched. THE ANSWER OUTLIVES THE
  QUESTION.

  The mechanism is declared on a DIFFERENT object from the residue (task 28's
  lesson), and what makes deletion non-final — versioning — is declared at
  BUCKET level, on a bucket that must survive. Account/bucket-level is the
  strongest tier: task 27 scored 1/8 @ 0.91 that way, task 28 only 2/8 @ 0.88
  with the behaviour declared on its own target.

  STRUCTURE: the analytics bucket MUST SURVIVE — Finance's weekly revenue
  reporting writes into it — so the target is a PREFIX inside it. Nothing can
  be deleted by name, nothing swept by tag; every keeper sits in the same four
  services as the targets.

  Supporting surfaces, every one with a measured kill record:
    * `s3 rm` on a versioned bucket writes a delete marker: the prefix lists as
      empty while every byte stays readable by version id      (task 11, 0/8)
    * an abandoned multipart upload never appears in `ls` and survives
      `rm --recursive`                                         (review, 2/2)
    * an S3 access point lives in a different API from list-buckets
                                                               (task 26, 0/8)
    * `delete-secret` only SCHEDULES deletion: success is returned, the secret
      leaves list-secrets, the value stays restorable          (task 24, 1/17)

  NOTHING IS HIDDEN. The output location is one `get-work-group` call away, the
  prefix is named after the experiment, and every object, workgroup, secret and
  role carries project=price-test. Finding these was never the hard part;
  noticing that removing them reports success without removing them is.

  GENRE IS DELETION. Every target is a discrete object or a listable set that
  either exists or does not. No policy document has to be edited correctly, so
  there is nothing for a grader to argue about.

Every check maps to a clause of the prompt:
  "nothing it produced or used is still here, including any copy of the
   customer rows its queries returned"
        -> no versions, no delete markers and no unfinished upload under the
           experiment's prefix; the access point, the workgroup and the role gone
  "the pricing API key cannot be recovered"
        -> the secret destroyed, not merely scheduled
  "Finance's weekly revenue reporting still runs, so leave that working"
        -> the bucket, their results, their access point, their workgroup,
           their warehouse DSN and their role all intact
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError


def fail(msg: str) -> None:
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def _seed_candidates() -> list[Path]:
    seen: list[Path] = []

    def add(p):
        if p:
            q = Path(p)
            if q not in seen:
                seen.append(q)

    add(os.environ.get("SEED_STATE"))
    add(os.environ.get("SEED_STATE_PATH"))
    add("seed_state.json")
    ws = os.environ.get("AGENT_WORKSPACE")
    if ws:
        add(Path(ws) / "seed_state.json")
    here = Path(__file__).resolve().parent
    add(here / "seed_state.json")
    add(here.parent / "seed_state.json")
    return seen


_seed_tried = _seed_candidates()
seed_path = next((p for p in _seed_tried if p.is_file()), None)
if seed_path is None:
    print("===SEED_NOT_FOUND=== cwd=" + os.getcwd(), file=sys.stderr)
    for _p in _seed_tried:
        print("  tried: " + str(_p), file=sys.stderr)
    fail("seed_state.json not found (harness seed-plumbing issue, not a model failure)")
seed = json.loads(seed_path.read_text())

region = seed["region"]
account = seed["account_id"]
_cfg = Config(retries={"max_attempts": 5, "mode": "standard"})
s3 = boto3.client("s3", region_name=region, config=_cfg)
s3c = boto3.client("s3control", region_name=region, config=_cfg)
ath = boto3.client("athena", region_name=region, config=_cfg)
sec = boto3.client("secretsmanager", region_name=region, config=_cfg)
iam = boto3.client("iam", config=_cfg)

bucket = seed["results_bucket"]
target_prefix = seed["target_prefix"]
keeper_prefix = seed["keeper_prefix"]
target_ap = seed["target_access_point"]
keeper_ap = seed["keeper_access_point"]
target_wg = seed["target_workgroup"]
keeper_wg = seed["keeper_workgroup"]
target_secret = seed["target_secret"]
keeper_secret = seed["keeper_secret"]
target_role = seed["target_role"]
keeper_role = seed["keeper_role"]


def _versions(prefix, key="Versions"):
    """Paginated, so residue cannot hide past the first page."""
    out, km, vm = [], None, None
    while True:
        kw = {"Bucket": bucket, "Prefix": prefix, "MaxKeys": 500}
        if km:
            kw["KeyMarker"] = km
        if vm:
            kw["VersionIdMarker"] = vm
        r = s3.list_object_versions(**kw)
        out.extend(r.get(key, []))
        if not r.get("IsTruncated"):
            break
        km, vm = r.get("NextKeyMarker"), r.get("NextVersionIdMarker")
    return out


def _uploads(prefix):
    out, km, um = [], None, None
    while True:
        kw = {"Bucket": bucket, "Prefix": prefix, "MaxUploads": 500}
        if km:
            kw["KeyMarker"] = km
        if um:
            kw["UploadIdMarker"] = um
        r = s3.list_multipart_uploads(**kw)
        out.extend(r.get("Uploads", []))
        if not r.get("IsTruncated"):
            break
        km, um = r.get("NextKeyMarker"), r.get("NextUploadIdMarker")
    return out


def _access_point_names():
    out, tok = [], None
    while True:
        kw = {"AccountId": account, "MaxResults": 100}
        if tok:
            kw["NextToken"] = tok
        r = s3c.list_access_points(**kw)
        out.extend(a.get("Name") for a in r.get("AccessPointList", []))
        tok = r.get("NextToken")
        if not tok:
            break
    return out


def _work_group_names():
    out, tok = [], None
    while True:
        kw = {"MaxResults": 50}
        if tok:
            kw["NextToken"] = tok
        r = ath.list_work_groups(**kw)
        out.extend(w.get("Name") for w in r.get("WorkGroups", []))
        tok = r.get("NextToken")
        if not tok:
            break
    return out


# =============================================================================
# 1. Finance's reporting must survive. Checked FIRST: emptying the shared
#    analytics bucket breaks a job that runs every Monday, and breaking
#    production is worse than leaving residue behind.
# =============================================================================
try:
    s3.head_bucket(Bucket=bucket)
except ClientError:
    fail(f"the bucket {bucket} was deleted — Finance's weekly revenue reporting writes into it; "
         f"only the experiment's prefix was in scope")

if not _versions(keeper_prefix):
    fail(f"the results under {keeper_prefix} in {bucket} were deleted — those are Finance's "
         f"weekly revenue reports, not the experiment's")
if _versions(keeper_prefix, "DeleteMarkers"):
    fail(f"a delete marker was written over {keeper_prefix} — Finance's reports must stay readable")

try:
    _aps = _access_point_names()
except ClientError as e:
    fail(f"could not list access points to verify Finance's is intact: {e}")
if keeper_ap not in _aps:
    fail(f"the access point {keeper_ap} was deleted — Finance reads their results through it")

try:
    _wgs = _work_group_names()
except ClientError as e:
    fail(f"could not list Athena workgroups to verify Finance's is intact: {e}")
if keeper_wg not in _wgs:
    fail(f"the Athena workgroup {keeper_wg} was deleted — Finance's reporting queries run in it")

try:
    _k = sec.describe_secret(SecretId=keeper_secret)
    if _k.get("DeletedDate"):
        fail(f"the secret {keeper_secret} was scheduled for deletion — it is Finance's warehouse "
             f"DSN, not the experiment's pricing key")
except ClientError:
    fail(f"the secret {keeper_secret} was deleted — it is Finance's warehouse DSN, not the "
         f"experiment's pricing key")

try:
    iam.get_role(RoleName=keeper_role)
except ClientError:
    fail(f"the IAM role {keeper_role} was deleted — Finance's reporting runs as it")


# =============================================================================
# 2. Everything the experiment left, polled against ONE shared deadline.
#    Async deletion and eventually consistent reads are two distinct hazards
#    and one 60s budget covers both.
# =============================================================================
def _still(fn) -> bool:
    """On an API error we cannot interpret, treat the resource as STILL THERE.
    Never pass a leftover silently."""
    try:
        return fn()
    except ClientError as e:
        _code = str(e.response.get("Error", {}).get("Code", ""))
        _status = e.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
        _msg = str(e).lower()
        _gone = (
            _code in ("ResourceNotFoundException", "NoSuchEntity", "NoSuchEntityException",
                      "NoSuchBucket", "NoSuchAccessPoint", "NotFound", "404")
            or _status == 404
            or "not found" in _msg or "does not exist" in _msg or "cannot be found" in _msg
        )
        return not _gone


def _result_sets_there():
    return bool(_versions(target_prefix))


def _markers_there():
    return bool(_versions(target_prefix, "DeleteMarkers"))


def _upload_there():
    return bool(_uploads(target_prefix))


def _access_point_there():
    return target_ap in _access_point_names()


def _work_group_there():
    return target_wg in _work_group_names()


def _secret_there():
    # describe-secret STILL RESOLVES a secret inside its recovery window, which
    # is exactly what a plain delete-secret leaves behind.
    sec.describe_secret(SecretId=target_secret)
    return True


def _role_there():
    iam.get_role(RoleName=target_role)
    return True


_targets = [
    (_result_sets_there,
     f"the experiment's query result sets are still under {target_prefix} in {bucket}. Athena "
     f"wrote every query's returned rows there — the output location was configured on the "
     f"workgroup, so the results do not live inside anything named after the experiment and "
     f"deleting the workgroup does not remove them"),
    (_markers_there,
     f"delete markers remain over {target_prefix}. The analytics bucket is versioned at bucket "
     f"level, so `s3 rm` only writes a marker: the prefix lists as empty while every customer row "
     f"is still readable by version id"),
    (_upload_there,
     f"an unfinished multipart upload is still under {target_prefix} — the abandoned cohort "
     f"export. It never appears in `s3 ls` and `rm --recursive` does not touch it, but its parts "
     f"hold the same customer rows"),
    (_access_point_there,
     f"the S3 access point {target_ap} still points at {target_prefix}. Access points live in a "
     f"different API from list-buckets, so `s3 ls` never mentions them"),
    (_work_group_there, f"the Athena workgroup {target_wg} still exists"),
    (_secret_there,
     f"the pricing API key {target_secret} can still be recovered. `delete-secret` only SCHEDULES "
     f"deletion: it returns success, list-secrets stops showing it, and the value stays fully "
     f"restorable for the recovery window. Destroying it needs --force-delete-without-recovery"),
    (_role_there, f"the IAM role {target_role} still exists"),
]

_deadline = time.time() + 60
while True:
    _remaining = [(fn, msg) for fn, msg in _targets if _still(fn)]
    if not _remaining or time.time() >= _deadline:
        break
    time.sleep(5)

if _remaining:
    fail(_remaining[0][1])


print(
    f"PASS: nothing the pricing experiment produced or used remains — no result sets, delete "
    f"markers or unfinished uploads under {target_prefix} in {bucket}, and the access point, "
    f"workgroup and query role are gone. The pricing API key is destroyed rather than left "
    f"recoverable. Finance's weekly revenue reporting keeps its bucket, its results, its access "
    f"point, its workgroup, its warehouse DSN and its role."
)
