#!/usr/bin/env bash
# Deletes the vera2-cw-pin-* schedules and roles and the
# vera2-high-order-errors-* alarms.
set -euo pipefail

python3 - <<'PY'
import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
cw = boto3.client("cloudwatch", region_name=REGION)
iam = boto3.client("iam", region_name=REGION)
sch = boto3.client("scheduler", region_name=REGION)


def swallow(fn):
    try:
        fn()
    except ClientError:
        pass


# schedules
token = None
while True:
    kw = {"NextToken": token} if token else {}
    page = sch.list_schedules(**kw)
    for s in page.get("Schedules", []):
        if s["Name"].startswith("vera2-cw-pin-"):
            swallow(lambda s=s: sch.delete_schedule(Name=s["Name"]))
    token = page.get("NextToken")
    if not token:
        break

# roles
for r in iam.list_roles().get("Roles", []):
    if r["RoleName"].startswith("vera2-cw-pin-role-"):
        for p in iam.list_role_policies(RoleName=r["RoleName"]).get("PolicyNames", []):
            swallow(lambda r=r, p=p: iam.delete_role_policy(RoleName=r["RoleName"], PolicyName=p))
        swallow(lambda r=r: iam.delete_role(RoleName=r["RoleName"]))

# alarms
token = None
while True:
    kw = {"NextToken": token} if token else {}
    page = cw.describe_alarms(AlarmNamePrefix="vera2-high-order-errors-", **kw)
    names = [a["AlarmName"] for a in page.get("MetricAlarms", [])]
    if names:
        swallow(lambda names=names: cw.delete_alarms(AlarmNames=names))
    token = page.get("NextToken")
    if not token:
        break
PY
