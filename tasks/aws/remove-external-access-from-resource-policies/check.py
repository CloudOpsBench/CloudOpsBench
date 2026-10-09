"""Grader: exit 0 = PASS.

A vera2 resource is "open to the outside" if a resource-based policy statement (Effect: Allow) grants access to a
wildcard principal "*" not genuinely pinned to this account by a Condition, or to an AWS account other than ours. This
grader checks the exact seeded resources across the services that carry a resource policy -- SNS and SQS (mainstream),
AND the two a service sweep tends to miss: a Kinesis stream resource-policy (returned only by get-resource-policy,
never by describe-stream) and an AWS HealthOmics sequence-store S3 access policy (returned only by
get-s3-access-policy, never by get-sequence-store). It checks the seeded resources by their recorded identifiers, not
a vera2- prefix sweep -- the namespace is shared across tasks, so another rollout's residue must never false-fail a
correct solver here. A Condition counts as pinning only when it binds a real account-scoping key
(aws:PrincipalAccount, aws:SourceAccount, aws:SourceOwner, aws:PrincipalArn, aws:PrincipalOrgID/OrgPaths) to this
account -- a self-assigned key such as a principal tag does not bind the caller to an account. Own-account access on
the sequence store must REMAIN (the prompt promises it): the store's S3 access policy must still grant this account,
so wiping the whole policy fails. Every seeded resource must still exist (secured, not deleted). Open verdicts are
re-read with a short backoff so a just-written policy is never misread. Reads run through the current awscli so
grading does not depend on the host boto3 version.
"""
import json
import time
import subprocess

import checkkit as ck

seed = ck.seed()
R = seed["region"]
ACCT = seed["account"]


def aws(*args):
    return subprocess.run(["aws", "--region", R, "--output", "json", *args],
                          capture_output=True, text=True)


def jload(result):
    s = (result.stdout or "").strip()
    return json.loads(s) if s else {}


def principals(stmt):
    pr = stmt.get("Principal", stmt.get("Principals"))
    vals = []
    if isinstance(pr, dict):
        for v in pr.values():
            vals += v if isinstance(v, list) else [v]
    elif isinstance(pr, list):
        vals = pr
    elif isinstance(pr, str):
        vals = [pr]
    return vals


def _pinning_entries(cond):
    for op, kv in (cond or {}).items():
        o = op.lower()
        if o.endswith("ifexists") or "not" in o:
            continue
        if not (o.startswith("string") or o.startswith("arn")):
            continue
        if not isinstance(kv, dict):
            continue
        for key, val in kv.items():
            yield key.lower(), (val if isinstance(val, list) else [val])


def condition_pins_to_account(cond):
    """True only for a Condition that genuinely binds the caller to this account. A key the caller controls
    (for example a principal tag) never pins, even if its value happens to contain our account id."""
    for k, vals in _pinning_entries(cond):
        if not vals:
            continue
        if k in ("aws:principalaccount", "aws:sourceaccount", "aws:sourceowner",
                 "aws:resourceaccount") and all(str(v) == ACCT for v in vals):
            return True
        if k == "aws:principalarn" and all((":" + ACCT + ":") in str(v) for v in vals):
            return True
        if k in ("aws:principalorgid", "aws:principalorgpaths"):
            return True
    return False


def account_of(principal):
    if principal == "*":
        return "*"
    if str(principal).isdigit():
        return str(principal)
    parts = str(principal).split(":")
    if len(parts) >= 5 and parts[4].isdigit():
        return parts[4]
    return None


def statements(doc):
    sts = doc.get("Statement", [])
    return [sts] if isinstance(sts, dict) else sts


def exposed(policy_json):
    if not policy_json:
        return False
    doc = json.loads(policy_json)
    for s in statements(doc):
        if s.get("Effect", "Allow") != "Allow":
            continue
        cond = s.get("Condition")
        for p in principals(s):
            acct = account_of(p)
            if acct == "*":
                if not condition_pins_to_account(cond):
                    return True
            elif acct and acct != ACCT:
                return True
    return False


def own_grant_present(policy_json):
    if not policy_json:
        return False
    doc = json.loads(policy_json)
    for s in statements(doc):
        if s.get("Effect", "Allow") != "Allow":
            continue
        for p in principals(s):
            if account_of(p) == ACCT:
                return True
    return False


missing = []
if aws("sns", "get-topic-attributes", "--topic-arn", seed["sns_topic_arn"]).returncode != 0:
    missing.append("SNS topic")
if aws("sqs", "get-queue-attributes", "--queue-url", seed["sqs_queue_url"], "--attribute-names", "QueueArn").returncode != 0:
    missing.append("SQS queue")
if aws("kinesis", "describe-stream-summary", "--stream-name", seed["kinesis_stream"]).returncode != 0:
    missing.append("Kinesis stream " + seed["kinesis_stream"])
if aws("omics", "get-sequence-store", "--id", seed["omics_store_id"]).returncode != 0:
    missing.append("HealthOmics sequence store " + seed["omics_store_id"])
ck.require(
    not missing,
    "Task-owned resources must be secured, not deleted. Problem with: " + ", ".join(missing),
)


def omics_policy():
    gs = aws("omics", "get-sequence-store", "--id", seed["omics_store_id"])
    if gs.returncode != 0:
        return None
    ap = jload(gs).get("s3Access", {}).get("s3AccessPointArn")
    if not ap:
        return None
    pr = aws("omics", "get-s3-access-policy", "--s3-access-point-arn", ap)
    if pr.returncode != 0:
        return None
    return jload(pr).get("s3AccessPolicy")


def scan_open():
    found = []
    sns_attrs = aws("sns", "get-topic-attributes", "--topic-arn", seed["sns_topic_arn"])
    if sns_attrs.returncode == 0 and exposed(jload(sns_attrs).get("Attributes", {}).get("Policy")):
        found.append("SNS " + seed["sns_topic_arn"].split(":")[-1])
    sqs_attrs = aws("sqs", "get-queue-attributes", "--queue-url", seed["sqs_queue_url"], "--attribute-names", "Policy")
    if sqs_attrs.returncode == 0 and exposed(jload(sqs_attrs).get("Attributes", {}).get("Policy")):
        found.append("SQS " + seed["sqs_queue_url"].split("/")[-1])
    kp = aws("kinesis", "get-resource-policy", "--resource-arn", seed["kinesis_arn"])
    if kp.returncode == 0 and exposed(jload(kp).get("Policy")):
        found.append("Kinesis " + seed["kinesis_stream"])
    if exposed(omics_policy()):
        found.append("HealthOmics " + seed["omics_store_id"])
    return found


open_resources = scan_open()
for _ in range(2):
    if not open_resources:
        break
    time.sleep(20)
    open_resources = scan_open()

ck.require(
    not open_resources,
    "These vera2 resources still grant access to a principal outside this account (a wildcard without a genuine "
    "account-scoping condition, or an external account). EVERY service that carries a resource policy must be "
    "reviewed -- including Kinesis stream resource-policies (get-resource-policy) and AWS HealthOmics sequence-store "
    "S3 access policies (get-s3-access-policy). Still open: " + ", ".join(open_resources),
)

ck.require(
    own_grant_present(omics_policy()),
    "The sequence store's own-account access must remain: its S3 access policy no longer grants this account. "
    "Remove only the external grant (the prompt says this account's access must be left alone).",
)
ck.ok("no vera2 resource across SNS, SQS, Kinesis, or HealthOmics grants access outside this account; own-account access preserved")
