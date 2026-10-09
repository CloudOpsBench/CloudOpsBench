#!/usr/bin/env bash
# Cleanup. Never fails; a lane nuke resets state anyway.
set -uo pipefail
export MSYS_NO_PATHCONV=1

python3 <<'PY' || true
import json
import os

import boto3

path = os.path.join(os.environ.get("TASK_STATE_DIR") or ".", "seed_state.json")
try:
    seed = json.load(open(path))
except Exception:
    raise SystemExit(0)

for region_key, arn_key in (("region", "secret_arn"), ("west_region", "west_secret_arn"),
                            ("region", "other_arn")):
    try:
        boto3.client("secretsmanager", region_name=seed[region_key]).delete_secret(
            SecretId=seed[arn_key], ForceDeleteWithoutRecovery=True)
    except Exception:
        pass

for region_key, fam_key in (("region", "east_families"), ("west_region", "west_families")):
    try:
        ecs = boto3.client("ecs", region_name=seed[region_key])
        for family in seed.get(fam_key, []):
            for status in ("ACTIVE", "INACTIVE"):
                try:
                    for arn in ecs.list_task_definitions(
                            familyPrefix=family, status=status)["taskDefinitionArns"]:
                        if status == "ACTIVE":
                            ecs.deregister_task_definition(taskDefinition=arn)
                except Exception:
                    pass
    except Exception:
        pass

try:
    iam = boto3.client("iam")
    for policy in iam.list_role_policies(RoleName=seed["role_name"])["PolicyNames"]:
        iam.delete_role_policy(RoleName=seed["role_name"], PolicyName=policy)
    iam.delete_role(RoleName=seed["role_name"])
except Exception:
    pass
print("teardown done")
PY
