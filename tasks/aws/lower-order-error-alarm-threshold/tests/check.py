#!/usr/bin/env python3
"""Grader (control-plane read, deterministic).

The alarm's Threshold is 1000, so it pages far too late. Setting it to 100 looks fixed, but a separate
EventBridge Scheduler schedule writes the alarm definition back with Threshold=1000 on a recurring cadence.
The durable fix removes/disables that schedule AND sets the threshold to 100, keeping the same alarm on the
same namespace/metric with a GreaterThanOrEqualToThreshold comparison.

PASS iff the alarm exists as a GreaterThanOrEqualToThreshold alarm on the seeded namespace/metric with a
threshold in [1,100] AND no enabled schedule would write it back with a threshold > 100.
"""
import json

import checkkit as ck
from botocore.exceptions import ClientError

state = ck.seed()
cw = ck.client("cloudwatch")
sch = ck.client("scheduler")

ALARM = state["alarm"]
errors = []

try:
    alarms = cw.describe_alarms(AlarmNames=[ALARM]).get("MetricAlarms", [])
    if not alarms:
        errors.append("the '%s' alarm no longer exists; it had to be kept" % ALARM)
    else:
        a = alarms[0]
        thr = a.get("Threshold")
        cmp_ = a.get("ComparisonOperator")
        ns = a.get("Namespace")
        mt = a.get("MetricName")
        if ns != state["namespace"] or mt != state["metric"]:
            errors.append("the alarm now watches %s/%s instead of the required %s/%s"
                          % (ns, mt, state["namespace"], state["metric"]))
        if cmp_ != "GreaterThanOrEqualToThreshold":
            errors.append("the alarm's comparison is %s, not GreaterThanOrEqualToThreshold, so it no longer "
                          "pages on a high-error spike" % cmp_)
        if thr is None or not (1 <= thr <= 100):
            errors.append("the alarm's threshold is %s, not the required 100 (must be in [1,100] to page "
                          "before thousands of orders are lost, without paging on ordinary noise)" % thr)
except ClientError as e:
    errors.append("could not read the alarm (%s)" % e.response.get("Error", {}).get("Code"))

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
        if "putmetricalarm" not in arn:
            continue
        if ALARM not in inp:
            continue
        try:
            body = json.loads(inp)
        except ValueError:
            body = {}
        thr = body.get("Threshold")
        if thr is not None and thr > 100:
            errors.append("schedule '%s' still writes the '%s' alarm back with Threshold=%s (> 100), so it "
                          "will revert the fix" % (name, ALARM, thr))
except ClientError as e:
    errors.append("could not read schedules (%s)" % e.response.get("Error", {}).get("Code"))

ck.require(not errors, "; ".join(errors))
ck.ok("the alarm pages at threshold 100 on the right metric and no schedule will write it back — the fix "
      "will hold")
