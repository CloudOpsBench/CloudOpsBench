#!/usr/bin/env bash
# Creates a provisioned DynamoDB table whose write-capacity scalable target is
# pinned at Min=Max=2 with a target-tracking policy, plus an EventBridge Scheduler
# schedule that re-registers the target at Min=Max=2 every 30 minutes.
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
ddb = boto3.client("dynamodb", region_name=REGION)
aas = boto3.client("application-autoscaling", region_name=REGION)
iam = boto3.client("iam", region_name=REGION)
sch = boto3.client("scheduler", region_name=REGION)

SFX = uuid.uuid4().hex[:8]
TABLE = "vera2-orders-%s" % SFX
RID = "table/%s" % TABLE
DIM = "dynamodb:table:WriteCapacityUnits"
POLICY = "vera2-orders-wcu-track-%s" % SFX
ROLE = "vera2-orders-pin-role-%s" % SFX
SCHEDULE = "vera2-orders-pin-%s" % SFX


def code(e):
    return e.response.get("Error", {}).get("Code", "ClientError")


for fn in (lambda: aas.deregister_scalable_target(ServiceNamespace="dynamodb", ResourceId=RID,
                                                  ScalableDimension=DIM),
           lambda: ddb.delete_table(TableName=TABLE)):
    try:
        fn()
    except ClientError:
        pass

ddb.create_table(
    TableName=TABLE,
    AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
    KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
    BillingMode="PROVISIONED",
    ProvisionedThroughput={"ReadCapacityUnits": 5, "WriteCapacityUnits": 2},
    Tags=[{"Key": "Project", "Value": "vera2"}])
ddb.get_waiter("table_exists").wait(TableName=TABLE)

aas.register_scalable_target(ServiceNamespace="dynamodb", ResourceId=RID, ScalableDimension=DIM,
                             MinCapacity=2, MaxCapacity=2)

aas.put_scaling_policy(
    PolicyName=POLICY, ServiceNamespace="dynamodb", ResourceId=RID, ScalableDimension=DIM,
    PolicyType="TargetTrackingScaling",
    TargetTrackingScalingPolicyConfiguration={
        "TargetValue": 70.0,
        "PredefinedMetricSpecification": {"PredefinedMetricType": "DynamoDBWriteCapacityUtilization"},
        "ScaleInCooldown": 60, "ScaleOutCooldown": 60})

trust = {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"Service": "scheduler.amazonaws.com"}, "Action": "sts:AssumeRole"}]}
role_arn = iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(trust),
                           Tags=[{"Key": "Project", "Value": "vera2"}])["Role"]["Arn"]
iam.put_role_policy(RoleName=ROLE, PolicyName="repin", PolicyDocument=json.dumps({
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Action": ["application-autoscaling:RegisterScalableTarget"],
                   "Resource": "*"}]}))

target_input = {"ServiceNamespace": "dynamodb", "ResourceId": RID, "ScalableDimension": DIM,
                "MinCapacity": 2, "MaxCapacity": 2}
start_date = datetime.datetime.utcnow() + datetime.timedelta(days=1)
deadline = time.monotonic() + 150
while True:
    try:
        sch.create_schedule(
            Name=SCHEDULE, ScheduleExpression="rate(30 minutes)", StartDate=start_date,
            FlexibleTimeWindow={"Mode": "OFF"},
            Target={"Arn": "arn:aws:scheduler:::aws-sdk:applicationautoscaling:registerScalableTarget",
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

state = {
    "region": REGION, "suffix": SFX, "table": TABLE, "resource_id": RID, "dimension": DIM,
    "policy": POLICY, "role": ROLE, "schedule": SCHEDULE, "want_min": 2, "want_max": 10,
}
with open("seed_state.json", "w") as h:
    json.dump(state, h, indent=2, sort_keys=True)

print("seeded: table %s write-capacity scalable target pinned Min=Max=2 with a target-tracking policy; a "
      "separate EventBridge Scheduler schedule %s re-registers it at Min=Max=2 every 30 minutes"
      % (TABLE, SCHEDULE))
PY
