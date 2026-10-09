#!/usr/bin/env bash
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

python3 - <<'PY'
import json, os, time
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

T0 = time.time()
BUDGET = float(os.environ.get("SETUP_BUDGET_SEC", "300"))   # exit under the platform cap, loudly
CFG = Config(connect_timeout=5, read_timeout=20, retries={"max_attempts": 3, "mode": "standard"})


def left():
    return BUDGET - (time.time() - T0)


def note(msg):
    print("setup[%5.1fs] %s" % (time.time() - T0, msg), flush=True)   # liveness on stdout


REGION = os.environ.get("AWS_REGION", "us-east-1")
iam = boto3.client("iam", region_name=REGION, config=CFG)
gg = boto3.client("greengrassv2", region_name=REGION, config=CFG)
sts = boto3.client("sts", region_name=REGION, config=CFG)
note("clients built; calling sts")
ACCT = sts.get_caller_identity()["Account"]
note("account %s, region %s" % (ACCT, REGION))

RETIRED = "vera2-fleet-telemetry-role"
KEEP = "vera2-fleet-deploy-role"
TRUST = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
         "Principal": {"Service": "greengrass.amazonaws.com"}, "Action": "sts:AssumeRole"}]}
INLINE = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Action": [
    "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
    "s3:GetObject"], "Resource": "*"}]}
OPS = "vera2-fleet-ops-role"
OPS_TRUST = {"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
             "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]}
OPS_POLICY = "legacy-telemetry-access"

def soft(fn, **kw):
    try:
        return fn(**kw)
    except ClientError:
        return None

def drop_role(name):
    for p in (soft(iam.list_role_policies, RoleName=name) or {}).get("PolicyNames", []):
        soft(iam.delete_role_policy, RoleName=name, PolicyName=p)
    soft(iam.delete_role, RoleName=name)

soft(gg.disassociate_service_role_from_account)
for _n in (KEEP, RETIRED, OPS):   # only this task's own roles: a prefix sweep reaches other tasks' seeds
    drop_role(_n)
note("prior state cleared")

def make_role(name):
    arn = iam.create_role(RoleName=name,
                          AssumeRolePolicyDocument=json.dumps(TRUST))["Role"]["Arn"]
    iam.put_role_policy(RoleName=name, PolicyName="inline", PolicyDocument=json.dumps(INLINE))
    return arn

def wait_role(name, want, floor):
    """Poll instead of sleeping a fixed span: usually a second or two, and it gives up on the budget."""
    while left() > floor:
        if bool(soft(iam.get_role, RoleName=name)) == want:
            return True
        time.sleep(2)
    return False

keep_arn = make_role(KEEP)
retired_arn = make_role(RETIRED)
wait_role(RETIRED, True, 60)
note("roles created and visible to IAM")

last = None
while left() > 90:
    try:
        gg.associate_service_role_to_account(roleArn=retired_arn)
        break
    except ClientError as exc:
        last = exc.response["Error"]["Code"]
        note("associate retry (%s), %.0fs left" % (last, left()))
        time.sleep(5)
else:
    raise SystemExit("setup: could not associate the service role: %s" % last)

while left() > 60:
    got = (soft(gg.get_service_role_for_account) or {}).get("roleArn")
    if got == retired_arn:
        break
    time.sleep(3)
else:
    raise SystemExit("setup: the account never reported the seeded service role")
note("account reports the seeded service role")

drop_role(RETIRED)
wait_role(RETIRED, False, 30)
note("retired role deleted, the association is now dangling")

still = (soft(gg.get_service_role_for_account) or {}).get("roleArn")
if still != retired_arn:
    raise SystemExit("setup: the association did not survive the role deletion (got %r)" % still)

iam.create_role(RoleName=OPS, AssumeRolePolicyDocument=json.dumps(OPS_TRUST),
                Description="fleet operations role")
iam.put_role_policy(RoleName=OPS, PolicyName=OPS_POLICY, PolicyDocument=json.dumps(
    {"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
     "Action": ["sts:AssumeRole", "iam:PassRole"], "Resource": retired_arn}]}))
wait_role(OPS, True, 30)
note("%s seeded with an inline policy naming the retired role" % OPS)

seeded_at = time.time()   # stamped last, so nothing this script made can read as the solver's work

keep_trust, keep_inline = None, {}   # baselines, so "left alone" is graded by content and not by existence
kr = soft(iam.get_role, RoleName=KEEP)
if kr:
    keep_trust = kr["Role"]["AssumeRolePolicyDocument"]
    for p in (soft(iam.list_role_policies, RoleName=KEEP) or {}).get("PolicyNames", []):
        pd = soft(iam.get_role_policy, RoleName=KEEP, PolicyName=p)
        if pd:
            keep_inline[p] = pd["PolicyDocument"]
keep_attached = []   # the rest of the keep-role's mutable surface, so "left alone" covers all of it
for pg in iam.get_paginator("list_attached_role_policies").paginate(RoleName=KEEP):
    keep_attached += [p["PolicyArn"] for p in pg.get("AttachedPolicies", [])]
_kr = (kr or {}).get("Role", {})
keep_surface = {"description": _kr.get("Description"),
                "max_session_duration": _kr.get("MaxSessionDuration"),
                "boundary": (_kr.get("PermissionsBoundary") or {}).get("PermissionsBoundaryArn"),
                "tags": sorted([t["Key"], t["Value"]] for t in _kr.get("Tags") or []),
                "attached": sorted(keep_attached)}
note("keep-role baseline recorded (%d inline policy document(s))" % len(keep_inline))

with open("seed_state.json", "w") as fh:
    json.dump({"account": ACCT, "region": REGION, "retired_role_name": RETIRED,
               "keep_trust_policy": keep_trust, "keep_inline_policies": keep_inline,
               "keep_surface": keep_surface,
               "ops_role_name": OPS, "ops_policy_name": OPS_POLICY,
               "retired_role_arn": retired_arn, "keep_role_name": KEEP, "keep_role_arn": keep_arn,
               "seeded_at": seeded_at}, fh)
print("setup: %s deleted; an IAM policy document and one account-level association both name it" % RETIRED)
PY
