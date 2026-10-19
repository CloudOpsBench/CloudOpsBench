#!/usr/bin/env bash
# Seeds the webhook signing-key secret in two regions, an unrelated payouts secret, a
# shared execution role, and ECS task definition families whose secret references pin
# the exposed version by id. Records the seeded state in seed_state.json.
set -euo pipefail
export MSYS_NO_PATHCONV=1

python3 <<'SEEDPY'
"""Seeds the relay webhook signing key, its regional copy, and the task definitions that read it."""
import json
import os
import secrets as pysecrets
import time

import boto3

EAST = os.environ.get("AWS_REGION") or "us-east-1"
WEST = "us-west-2" if EAST != "us-west-2" else "us-east-2"
sfx = pysecrets.token_hex(4)

sts = boto3.client("sts", region_name=EAST)
sm_e = boto3.client("secretsmanager", region_name=EAST)
sm_w = boto3.client("secretsmanager", region_name=WEST)
ecs_e = boto3.client("ecs", region_name=EAST)
ecs_w = boto3.client("ecs", region_name=WEST)
iam = boto3.client("iam", region_name=EAST)

ACCT = sts.get_caller_identity()["Account"]
SECRET = "relay-webhook-signing-key-%s" % sfx
OTHER = "relay-payout-batch-key-%s" % sfx
ROLE = "relay-webhook-exec-role-%s" % sfx
FAM_VERIFIER = "relay-webhook-verifier-%s" % sfx
FAM_DISPATCH = "relay-webhook-dispatch-%s" % sfx

EXPOSED = "whsec_%s" % pysecrets.token_hex(16)
OTHER_VALUE = "pbk_%s" % pysecrets.token_hex(10)

created = sm_e.create_secret(
    Name=SECRET,
    Description="Vendor webhook signing key read by the relay-webhook workloads",
    SecretString=json.dumps({"signing_key": EXPOSED}))
secret_arn, exposed_version = created["ARN"], created["VersionId"]

west = sm_w.create_secret(
    Name=SECRET,
    Description="Vendor webhook signing key read by the relay-webhook workloads",
    SecretString=json.dumps({"signing_key": EXPOSED}))
west_arn, west_exposed_version = west["ARN"], west["VersionId"]

other = sm_e.create_secret(
    Name=OTHER,
    Description="Payout batch submission key, owned by the payouts team",
    SecretString=json.dumps({"batch_key": OTHER_VALUE}))
other_arn = other["ARN"]
other_stages = sm_e.describe_secret(SecretId=other_arn)["VersionIdsToStages"]

role_arn = iam.create_role(
    RoleName=ROLE,
    Description="Task execution role for the relay-webhook workloads",
    AssumeRolePolicyDocument=json.dumps({
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow",
                       "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                       "Action": "sts:AssumeRole"}]}))["Role"]["Arn"]
iam.put_role_policy(
    RoleName=ROLE, PolicyName="read-webhook-signing-key",
    PolicyDocument=json.dumps({
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
                       "Resource": "arn:aws:secretsmanager:*:%s:secret:relay-webhook-signing-key-*"
                       % ACCT}]}))


def register(client, family, value_from):
    return client.register_task_definition(
        family=family, requiresCompatibilities=["FARGATE"], networkMode="awsvpc",
        cpu="256", memory="512", executionRoleArn=role_arn,
        containerDefinitions=[{
            "name": "app",
            "image": "public.ecr.aws/docker/library/alpine:3",
            "essential": True,
            "command": ["sh", "-c", "echo webhook worker"],
            "secrets": [{"name": "WEBHOOK_SIGNING_KEY", "valueFrom": value_from}],
        }])["taskDefinition"]["taskDefinitionArn"]


# Every family pins its region's exposed version by id.
pinned_e = "%s:signing_key::%s" % (secret_arn, exposed_version)
pinned_w = "%s:signing_key::%s" % (west_arn, west_exposed_version)
east_arns = {FAM_VERIFIER: register(ecs_e, FAM_VERIFIER, pinned_e),
             FAM_DISPATCH: register(ecs_e, FAM_DISPATCH, pinned_e)}
west_arns = {FAM_VERIFIER: register(ecs_w, FAM_VERIFIER, pinned_w)}

sm_e.update_secret_version_stage(SecretId=secret_arn, VersionStage="standby",
                                 MoveToVersionId=exposed_version)

for client, fams in ((ecs_e, [FAM_VERIFIER, FAM_DISPATCH]), (ecs_w, [FAM_VERIFIER])):
    for family in fams:
        for _ in range(45):
            if client.list_task_definitions(familyPrefix=family,
                                            status="ACTIVE")["taskDefinitionArns"]:
                break
            time.sleep(2)
        else:
            raise SystemExit("task definitions for %s never became listable" % family)

state = {
    "region": EAST, "west_region": WEST, "account": ACCT, "sfx": sfx,
    "secret_name": SECRET, "secret_arn": secret_arn,
    "west_secret_arn": west_arn,
    "exposed_value": EXPOSED, "exposed_version": exposed_version,
    "west_exposed_version": west_exposed_version,
    "other_name": OTHER, "other_arn": other_arn, "other_value": OTHER_VALUE,
    "other_stages": other_stages,
    "role_name": ROLE, "role_arn": role_arn,
    "east_families": [FAM_VERIFIER, FAM_DISPATCH],
    "west_families": [FAM_VERIFIER],
    "east_task_definitions": east_arns, "west_task_definitions": west_arns,
}
out = os.environ.get("TASK_STATE_DIR") or "."
with open(os.path.join(out, "seed_state.json"), "w") as fh:
    json.dump(state, fh, indent=2)
print("seeded relay webhook signing key %s" % sfx)
SEEDPY
