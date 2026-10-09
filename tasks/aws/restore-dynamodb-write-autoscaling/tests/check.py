#!/usr/bin/env python3
"""Check that the table's write capacity can auto-scale between 2 and 10 and stays that way.

Passes when the table is still provisioned, the write-capacity scalable target is
Min=2/Max=10, no enabled EventBridge Scheduler schedule re-registers the target with a
lower maximum or with Min equal to Max, and the target-tracking policy is still present.
"""
import json

import checkkit as ck
from botocore.exceptions import ClientError

state = ck.seed()
ddb = ck.client("dynamodb")
aas = ck.client("application-autoscaling")
sch = ck.client("scheduler")

RID = state["resource_id"]
DIM = state["dimension"]
WANT_MIN, WANT_MAX = state["want_min"], state["want_max"]
errors = []

# Table is still provisioned.
try:
    t = ddb.describe_table(TableName=state["table"])["Table"]
    bm = (t.get("BillingModeSummary") or {}).get("BillingMode", "PROVISIONED")
    if bm != "PROVISIONED":
        errors.append("the table is no longer PROVISIONED (billing=%s); keep it provisioned so it can "
                      "auto-scale write capacity" % bm)
except ClientError as e:
    errors.append("the table is gone (%s); it had to be kept" % e.response.get("Error", {}).get("Code"))

# Scalable target allows the required range.
try:
    tgts = aas.describe_scalable_targets(ServiceNamespace="dynamodb", ResourceIds=[RID],
                                         ScalableDimension=DIM)["ScalableTargets"]
    if not tgts:
        errors.append("write capacity is no longer a registered scalable target; it can't auto-scale")
    else:
        tgt = tgts[0]
        if tgt.get("MinCapacity") != WANT_MIN or tgt.get("MaxCapacity") != WANT_MAX:
            errors.append("the write-capacity scalable range is Min=%s/Max=%s, not the required Min=%s/Max=%s"
                          % (tgt.get("MinCapacity"), tgt.get("MaxCapacity"), WANT_MIN, WANT_MAX))
except ClientError as e:
    errors.append("could not read the scalable target (%s)" % e.response.get("Error", {}).get("Code"))

# No enabled schedule re-registers the target at a lower or fixed range.
try:
    names = []
    token = None
    while True:
        kw = {"NextToken": token} if token else {}
        page = sch.list_schedules(**kw)
        names.extend([s["Name"] for s in page.get("Schedules", [])])
        token = page.get("NextToken")
        if not token:
            break
    for name in names:
        try:
            sc = sch.get_schedule(Name=name)
        except ClientError:
            continue
        if sc.get("State") != "ENABLED":
            continue
        tgt = sc.get("Target") or {}
        arn = (tgt.get("Arn") or "").lower()
        inp = tgt.get("Input") or ""
        if "registerscalabletarget" not in arn:
            continue
        if RID not in inp:
            continue
        try:
            payload = json.loads(inp)
        except ValueError:
            payload = {}
        amin, amax = payload.get("MinCapacity"), payload.get("MaxCapacity")
        if amax is not None and amax < WANT_MAX:
            errors.append("schedule '%s' still re-registers the target with MaxCapacity %s (< %s), so it will "
                          "re-pin the table below the required range" % (name, amax, WANT_MAX))
        elif amin is not None and amax is not None and amin == amax:
            errors.append("schedule '%s' still re-registers the target with Min==Max=%s, so it will re-pin "
                          "the table to a fixed capacity" % (name, amin))
except ClientError as e:
    errors.append("could not read schedules (%s)" % e.response.get("Error", {}).get("Code"))

# Target-tracking scaling policy is still present.
try:
    pols = aas.describe_scaling_policies(ServiceNamespace="dynamodb", ResourceId=RID,
                                         ScalableDimension=DIM)["ScalingPolicies"]
    if not any(p.get("PolicyType") == "TargetTrackingScaling" for p in pols):
        errors.append("the target-tracking scaling policy is gone; it had to be kept so the table scales on "
                      "utilization")
except ClientError as e:
    errors.append("could not read scaling policies (%s)" % e.response.get("Error", {}).get("Code"))

ck.require(not errors, "; ".join(errors))
ck.ok("write capacity is a scalable target with Min=2/Max=10, no schedule re-pins it, and the target-tracking "
      "policy is intact — the table will now auto-scale and stay scalable")
