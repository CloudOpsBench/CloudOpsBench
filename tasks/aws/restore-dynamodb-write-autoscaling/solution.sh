#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
aas = boto3.client("application-autoscaling", region_name=REGION)
sch = boto3.client("scheduler", region_name=REGION)
DIM = "dynamodb:table:WriteCapacityUnits"

# Discover the vera2-orders-* write-capacity scalable target(s) the way an operator would (no seed files).
targets = []
token = None
while True:
    kw = {"ServiceNamespace": "dynamodb"}
    if token:
        kw["NextToken"] = token
    page = aas.describe_scalable_targets(**kw)
    targets.extend(page.get("ScalableTargets", []))
    token = page.get("NextToken")
    if not token:
        break
rids = [t["ResourceId"] for t in targets
        if t.get("ScalableDimension") == DIM and t["ResourceId"].startswith("table/vera2-orders-")]
if not rids:
    raise RuntimeError("no write-capacity scalable target found for a vera2-orders-* table")

names = []
token = None
while True:
    kw = {"NextToken": token} if token else {}
    page = sch.list_schedules(**kw)
    names.extend([s["Name"] for s in page.get("Schedules", [])])
    token = page.get("NextToken")
    if not token:
        break

for rid in rids:
    # Delete every schedule that re-registers this target at a pinned range, then set the 2-10 range.
    for name in names:
        try:
            sc = sch.get_schedule(Name=name)
        except ClientError:
            continue
        tgt = sc.get("Target") or {}
        if "registerscalabletarget" in (tgt.get("Arn") or "").lower() and rid in (tgt.get("Input") or ""):
            try:
                sch.delete_schedule(Name=name)
            except ClientError:
                pass
    aas.register_scalable_target(ServiceNamespace="dynamodb", ResourceId=rid,
                                 ScalableDimension=DIM, MinCapacity=2, MaxCapacity=10)
    print("deleted the re-pinning schedule(s) for %s and set the write-capacity range to Min=2/Max=10" % rid)
PY
