#!/usr/bin/env bash
# Creates a CloudWatch alarm with Threshold=1000 and an EventBridge Scheduler
# schedule that rewrites the alarm with the same definition every 30 minutes.
# The seeded state is recorded in seed_state.json for the checker.
set -euo pipefail

python3 - <<'PY'
import datetime
import json
import os
import time
import uuid

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
cw = boto3.client("cloudwatch", region_name=REGION)
iam = boto3.client("iam", region_name=REGION)
sch = boto3.client("scheduler", region_name=REGION)
acct = boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]

SFX = uuid.uuid4().hex[:8]
ALARM = "vera2-high-order-errors-%s" % SFX
NS = "vera2/orders"
METRIC = "OrderErrors"
ROLE = "vera2-cw-pin-role-%s" % SFX
SCHEDULE = "vera2-cw-pin-%s" % SFX
alarm_arn = "arn:aws:cloudwatch:%s:%s:alarm:%s" % (REGION, acct, ALARM)


def code(e):
    return e.response.get("Error", {}).get("Code", "ClientError")


alarm_def = {
    "AlarmName": ALARM,
    "AlarmDescription": "Page on-call when order errors spike",
    "Namespace": NS,
    "MetricName": METRIC,
    "Statistic": "Sum",
    "Period": 300,
    "EvaluationPeriods": 1,
    "ComparisonOperator": "GreaterThanOrEqualToThreshold",
    "Threshold": 1000,
    "TreatMissingData": "notBreaching",
}
cw.put_metric_alarm(Tags=[{"Key": "Project", "Value": "vera2"}], **alarm_def)

trust = {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "scheduler.amazonaws.com"}, "Action": "sts:AssumeRole"}]}
role_arn = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(trust),
                           Tags=[{"Key": "Project", "Value": "vera2"}])["Role"]["Arn"]
iam.put_role_policy(RoleName=ROLE, PolicyName="putalarm", PolicyDocument=json.dumps({
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Action": ["cloudwatch:PutMetricAlarm"], "Resource": alarm_arn}]}))

target_input = dict(alarm_def)  # same definition, Threshold stays 1000
start_date = datetime.datetime.utcnow() + datetime.timedelta(days=1)
deadline = time.monotonic() + 150
while True:
    try:
        sch.create_schedule(
            Name=SCHEDULE, ScheduleExpression="rate(30 minutes)", StartDate=start_date,
            FlexibleTimeWindow={"Mode": "OFF"},
            Target={"Arn": "arn:aws:scheduler:::aws-sdk:cloudwatch:putMetricAlarm",
                    "RoleArn": role_arn, "Input": json.dumps(target_input)},
            State="ENABLED")
        break
    except ClientError as e:
        if code(e) == "ConflictException":
            break
        if code(e) == "ValidationException" and time.monotonic() < deadline:
            time.sleep(5)
            continue
        raise

state = {"region": REGION, "suffix": SFX, "alarm": ALARM, "alarm_arn": alarm_arn,
         "namespace": NS, "metric": METRIC, "role": ROLE, "schedule": SCHEDULE, "max_ok": 100}
with open("seed_state.json", "w") as h:
    json.dump(state, h, indent=2, sort_keys=True)

print("seeded: alarm %s Threshold=1000 (too high to page before thousands of orders are lost); a separate "
      "dormant EventBridge Scheduler %s writes the alarm back with Threshold=1000 every 30 minutes"
      % (ALARM, SCHEDULE))
PY
