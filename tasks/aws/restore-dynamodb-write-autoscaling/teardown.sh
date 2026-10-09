#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
ddb = boto3.client("dynamodb", region_name=REGION)
aas = boto3.client("application-autoscaling", region_name=REGION)
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
        if s["Name"].startswith("vera2-orders-pin-"):
            swallow(lambda s=s: sch.delete_schedule(Name=s["Name"]))
    token = page.get("NextToken")
    if not token:
        break

# roles
for r in iam.list_roles().get("Roles", []):
    if r["RoleName"].startswith("vera2-orders-pin-role-"):
        for p in iam.list_role_policies(RoleName=r["RoleName"]).get("PolicyNames", []):
            swallow(lambda r=r, p=p: iam.delete_role_policy(RoleName=r["RoleName"], PolicyName=p))
        swallow(lambda r=r: iam.delete_role(RoleName=r["RoleName"]))

# scalable targets + tables
for tbl in ddb.list_tables().get("TableNames", []):
    if not tbl.startswith("vera2-orders-"):
        continue
    rid = "table/%s" % tbl
    swallow(lambda rid=rid: aas.deregister_scalable_target(
        ServiceNamespace="dynamodb", ResourceId=rid, ScalableDimension="dynamodb:table:WriteCapacityUnits"))
    swallow(lambda tbl=tbl: ddb.delete_table(TableName=tbl))
PY
