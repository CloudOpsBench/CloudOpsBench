#!/usr/bin/env python3
"""Check that the table's write capacity can auto-scale between 2 and 10 and stays that way.

Passes when the table is still provisioned, the write-capacity scalable target is
Min=2/Max=10 with dynamic scaling not suspended, no enabled EventBridge Scheduler schedule
re-registers the target with any other range or with dynamic scaling suspended, and the
original table and target-tracking policy are still present with scale-in allowed.
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

try:
    t = ddb.describe_table(TableName=state["table"])["Table"]
    bm = (t.get("BillingModeSummary") or {}).get("BillingMode", "PROVISIONED")
    if t.get("TableId") != state["table_id"]:
        errors.append("the original table was deleted and recreated; repair the existing table in place")
    if bm != "PROVISIONED":
        errors.append("the table is no longer PROVISIONED (billing=%s); keep it provisioned so it can "
                      "auto-scale write capacity" % bm)
except ClientError as e:
    errors.append("the table is gone (%s); it had to be kept" % e.response.get("Error", {}).get("Code"))

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
        suspended = tgt.get("SuspendedState") or {}
        if (suspended.get("DynamicScalingInSuspended") is True or
                suspended.get("DynamicScalingOutSuspended") is True):
            errors.append("dynamic scaling is suspended on the write-capacity scalable target, so it cannot "
                          "scale on utilization")
except ClientError as e:
    errors.append("could not read the scalable target (%s)" % e.response.get("Error", {}).get("Code"))

try:
    listed = []
    token = None
    while True:
        kw = {"NextToken": token} if token else {}
        page = sch.list_schedules(**kw)
        listed.extend(page.get("Schedules", []))
        token = page.get("NextToken")
        if not token:
            break
    for item in listed:
        name = item["Name"]
        try:
            sc = sch.get_schedule(Name=name, GroupName=item.get("GroupName") or "default")
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") == "ResourceNotFoundException":
                continue
            raise
        if sc.get("State") != "ENABLED":
            continue
        tgt = sc.get("Target") or {}
        arn = (tgt.get("Arn") or "").lower()
        inp = tgt.get("Input") or ""
        if "registerscalabletarget" not in arn:
            continue
        try:
            payload = json.loads(inp)
        except (TypeError, ValueError):
            continue
        if not isinstance(payload, dict):
            continue
        if (payload.get("ServiceNamespace") != "dynamodb" or payload.get("ResourceId") != RID or
                payload.get("ScalableDimension") != DIM):
            continue
        amin, amax = payload.get("MinCapacity"), payload.get("MaxCapacity")
        bad_min = amin is not None and amin != WANT_MIN
        bad_max = amax is not None and amax != WANT_MAX
        if bad_min or bad_max:
            errors.append("schedule '%s' still re-registers the target with MinCapacity=%r/MaxCapacity=%r, so "
                          "it does not keep the required Min=%s/Max=%s range" %
                          (name, amin, amax, WANT_MIN, WANT_MAX))
        suspended = payload.get("SuspendedState")
        if isinstance(suspended, dict) and (suspended.get("DynamicScalingInSuspended") is True or
                                            suspended.get("DynamicScalingOutSuspended") is True):
            errors.append("schedule '%s' re-registers the target with dynamic scaling suspended" % name)
except ClientError as e:
    errors.append("could not read schedules (%s)" % e.response.get("Error", {}).get("Code"))

try:
    pols = aas.describe_scaling_policies(ServiceNamespace="dynamodb", ResourceId=RID,
                                         ScalableDimension=DIM)["ScalingPolicies"]
    original = [p for p in pols if p.get("PolicyName") == state["policy"]]
    if not original:
        errors.append("the original target-tracking scaling policy was deleted or replaced")
    elif original[0].get("PolicyARN") != state["policy_arn"]:
        errors.append("the original target-tracking scaling policy was deleted and recreated")
    elif original[0].get("PolicyType") != "TargetTrackingScaling":
        errors.append("the original scaling policy is no longer a target-tracking policy")
    elif (original[0].get("TargetTrackingScalingPolicyConfiguration") or {}).get("DisableScaleIn") is True:
        errors.append("the original target-tracking policy has scale-in disabled, so write capacity cannot "
                      "return to %s when utilization falls" % WANT_MIN)
except ClientError as e:
    errors.append("could not read scaling policies (%s)" % e.response.get("Error", {}).get("Code"))

ck.require(not errors, "; ".join(errors))
ck.ok("the original table and target-tracking policy are intact, write capacity is a scalable target with "
      "Min=2/Max=10, and no schedule re-pins it — the table will now auto-scale and stay scalable")
