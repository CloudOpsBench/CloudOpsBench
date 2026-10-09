#!/usr/bin/env bash
# Writes a new signing key to every copy of the secret, detaches version stages that
# still return the exposed key, re-registers the relay-webhook-* task definitions without
# the version pin, and deregisters active revisions that still resolve the exposed key.
set -euo pipefail
export MSYS_NO_PATHCONV=1

python3 <<'PY'
import json
import secrets as pysecrets

import boto3

HOME = boto3.session.Session().region_name or "us-east-1"
sm_home = boto3.client("secretsmanager", region_name=HOME)

arn = next(s["ARN"] for p in sm_home.get_paginator("list_secrets").paginate()
           for s in p["SecretList"]
           if s["Name"].startswith("relay-webhook-signing-key-"))
exposed = sm_home.get_secret_value(SecretId=arn)["SecretString"]
exposed_key = json.loads(exposed)["signing_key"]
NEW = "whsec_%s" % pysecrets.token_hex(16)
NEW_STRING = json.dumps({"signing_key": NEW})


def scrub_secret(sm, secret_id):
    """Put the same new key and detach every stage still serving the exposed one."""
    sm.put_secret_value(SecretId=secret_id, SecretString=NEW_STRING)
    for version, stages in sm.describe_secret(
            SecretId=secret_id)["VersionIdsToStages"].items():
        for stage in list(stages):
            if stage == "AWSCURRENT":
                continue
            try:
                still = sm.get_secret_value(SecretId=secret_id,
                                            VersionStage=stage)["SecretString"]
            except Exception:
                continue
            if exposed_key in still:
                sm.update_secret_version_stage(SecretId=secret_id, VersionStage=stage,
                                               RemoveFromVersionId=version)


# The home-region secret first.
scrub_secret(sm_home, arn)

try:
    regions = [r["RegionName"] for r in
               boto3.client("ec2", region_name=HOME).describe_regions()["Regions"]]
except Exception:
    regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "eu-west-1",
               "eu-central-1", "ap-southeast-1", "ap-northeast-1"]

for region in regions:
    sm = boto3.client("secretsmanager", region_name=region)
    ecs = boto3.client("ecs", region_name=region)
    try:
        secrets = [s for p in sm.get_paginator("list_secrets").paginate()
                   for s in p["SecretList"]
                   if s["Name"].startswith("relay-webhook-signing-key-")]
    except Exception:
        continue
    for s in secrets:
        if region == HOME and s["ARN"] == arn:
            continue
        if exposed_key in sm.get_secret_value(SecretId=s["ARN"])["SecretString"]:
            scrub_secret(sm, s["ARN"])
            print("scrubbed standalone copy %s in %s" % (s["Name"], region))

    def stale(value_from):
        """True if this reference still hands out the exposed key."""
        parts = value_from.split(":")
        if value_from.startswith("arn:"):
            secret_id, tail = ":".join(parts[:7]), parts[7:]
        else:
            secret_id, tail = parts[0], parts[1:]
        stage = tail[1] if len(tail) > 1 and tail[1] else None
        version = tail[2] if len(tail) > 2 and tail[2] else None
        try:
            if version:
                got = sm.get_secret_value(SecretId=secret_id,
                                          VersionId=version)["SecretString"]
            elif stage:
                got = sm.get_secret_value(SecretId=secret_id,
                                          VersionStage=stage)["SecretString"]
            else:
                got = sm.get_secret_value(SecretId=secret_id)["SecretString"]
        except Exception:
            return False
        return exposed_key in got

    def unpin(value_from):
        parts = value_from.split(":")
        head = ":".join(parts[:7]) if value_from.startswith("arn:") else parts[0]
        key = parts[7] if value_from.startswith("arn:") and len(parts) > 7 else (
            parts[1] if not value_from.startswith("arn:") and len(parts) > 1 else "")
        return "%s:%s::" % (head, key)

    try:
        families = ecs.list_task_definition_families(
            familyPrefix="relay-webhook-", status="ACTIVE")["families"]
    except Exception:
        continue
    for family in families:
        td = ecs.describe_task_definition(taskDefinition=family)["taskDefinition"]
        containers = td["containerDefinitions"]
        changed = False
        for c in containers:
            for entry in c.get("secrets", []):
                if stale(entry["valueFrom"]):
                    entry["valueFrom"] = unpin(entry["valueFrom"])
                    changed = True
        stale_revs = [a for a in ecs.list_task_definitions(
            familyPrefix=family, status="ACTIVE").get("taskDefinitionArns", [])
            if any(stale(sec["valueFrom"])
                   for c in ecs.describe_task_definition(
                       taskDefinition=a)["taskDefinition"].get("containerDefinitions", [])
                   for sec in c.get("secrets", []))]
        if changed:
            ecs.register_task_definition(
                family=family,
                requiresCompatibilities=td.get("requiresCompatibilities", []),
                networkMode=td["networkMode"], cpu=td["cpu"], memory=td["memory"],
                executionRoleArn=td["executionRoleArn"],
                containerDefinitions=containers)
            print("repointed ECS family %s in %s" % (family, region))
        # An old revision left ACTIVE can still be launched and still hands out the pin.
        for a in stale_revs:
            ecs.deregister_task_definition(taskDefinition=a)
print("webhook signing key replaced")
PY
