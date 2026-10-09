"""Grader: exit 0 = PASS.

Alarm actions must be disabled on ALL vera2 alarms. `aws cloudwatch describe-alarms` returns only metric
alarms by default — composite alarms are omitted unless you pass --alarm-types (e.g. "CompositeAlarm").
A correct solution disables actions on every vera2 alarm, metric AND composite.
"""
import boto3
import checkkit as ck

seed = ck.seed()
reg = seed["region"]
cw = boto3.client("cloudwatch", region_name=reg)
names = seed["metric_alarms"] + seed["composite_alarms"]

resp = cw.describe_alarms(AlarmNames=names, AlarmTypes=["MetricAlarm", "CompositeAlarm"])
state = {a["AlarmName"]: a.get("ActionsEnabled") for a in resp.get("MetricAlarms", []) + resp.get("CompositeAlarms", [])}

bad = []
for n in names:
    ae = state.get(n)
    if ae is None:
        bad.append("%s: not found" % n)
    elif ae:
        bad.append("%s: actions still ENABLED" % n)

ck.require(
    not bad,
    "Not all vera2 alarms have their actions disabled. `describe-alarms` returns only metric alarms by "
    "default; composite alarms are excluded unless --alarm-types CompositeAlarm is passed. Still enabled/"
    "missing: %s" % "; ".join(bad),
)
ck.ok("alarm actions disabled on all vera2 alarms (metric and composite)")
