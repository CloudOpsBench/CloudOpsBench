#!/usr/bin/env bash
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

python3 - <<'PY'
import os
import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
gg = boto3.client("greengrassv2", region_name=REGION)
iam = boto3.client("iam", region_name=REGION)

def soft(fn, **kw):
    try:
        return fn(**kw)
    except ClientError:
        return None

soft(gg.disassociate_service_role_from_account)
for n in ("vera2-fleet-telemetry-role", "vera2-fleet-deploy-role", "vera2-fleet-ops-role"):
    for p in (soft(iam.list_role_policies, RoleName=n) or {}).get("PolicyNames", []):
        soft(iam.delete_role_policy, RoleName=n, PolicyName=p)
    soft(iam.delete_role, RoleName=n)
print("teardown: removed the service-role association and the vera2 roles")
PY
