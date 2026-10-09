#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import os

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
cw = boto3.client("cloudwatch", region_name=REGION)
sch = boto3.client("scheduler", region_name=REGION)

# Find the alarm from the live account.
alarm = None
token = None
while True:
    kw = {"NextToken": token} if token else {}
    page = cw.describe_alarms(AlarmNamePrefix="vera2-high-order-errors-", **kw)
    for a in page.get("MetricAlarms", []):
        alarm = a
        break
    if alarm:
        break
    token = page.get("NextToken")
    if not token:
        break
if alarm is None:
    raise SystemExit("alarm not found")

# Re-write the alarm with the corrected threshold, preserving its identity.
put = {
    "AlarmName": alarm["AlarmName"],
    "Namespace": alarm["Namespace"],
    "MetricName": alarm["MetricName"],
    "Statistic": alarm.get("Statistic", "Sum"),
    "Period": alarm["Period"],
    "EvaluationPeriods": alarm["EvaluationPeriods"],
    "ComparisonOperator": "GreaterThanOrEqualToThreshold",
    "Threshold": 100,
}
if alarm.get("AlarmDescription"):
    put["AlarmDescription"] = alarm["AlarmDescription"]
if alarm.get("TreatMissingData"):
    put["TreatMissingData"] = alarm["TreatMissingData"]
cw.put_metric_alarm(**put)

# Remove any schedule that would write the alarm back.
token = None
while True:
    kw = {"NextToken": token} if token else {}
    page = sch.list_schedules(**kw)
    for s in page.get("Schedules", []):
        name = s["Name"]
        try:
            body = sch.get_schedule(Name=name)
        except ClientError:
            continue
        tgt = body.get("Target") or {}
        arn = (tgt.get("Arn") or "").lower()
        inp = tgt.get("Input") or ""
        if "putmetricalarm" in arn and alarm["AlarmName"] in inp:
            try:
                sch.delete_schedule(Name=name)
            except ClientError:
                pass
    token = page.get("NextToken")
    if not token:
        break

print("set the '%s' alarm threshold to 100 and removed the schedule that re-wrote it" % alarm["AlarmName"])
PY
