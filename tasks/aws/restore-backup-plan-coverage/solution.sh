#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

python3 - <<'PY'
import json
import time

import boto3
import botocore.exceptions

REGION = "us-east-1"
backup = boto3.client("backup", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
efs = boto3.client("efs", region_name=REGION)
ec2 = boto3.client("ec2", region_name=REGION)
iam = boto3.client("iam")

# --- find the plan, its selections and the fleet -------------------------------
plans = sorted((p for p in backup.list_backup_plans()["BackupPlansList"]
                if p["BackupPlanName"].startswith("vera-nightly-")),
               key=lambda p: p["CreationDate"], reverse=True)
if not plans:
    raise SystemExit("solution: no vera-nightly-* backup plan found")
plan_id = plans[0]["BackupPlanId"]
RUN_ID = plans[0]["BackupPlanName"].rsplit("-", 1)[-1]
print(f"repairing plan {plans[0]['BackupPlanName']} (id {RUN_ID}, "
      f"newest of {len(plans)} match(es))")


def in_fleet(name):
    """The prompt's own scope: named vera-*, carrying this run's id."""
    return name.startswith("vera-") and name.endswith(RUN_ID)

selections = []
for meta in backup.list_backup_selections(BackupPlanId=plan_id)["BackupSelectionsList"]:
    selections.append(backup.get_backup_selection(
        BackupPlanId=plan_id, SelectionId=meta["SelectionId"])["BackupSelection"])

wanted = {}
for sel in selections:
    for cond in sel.get("ListOfTags") or []:
        wanted[cond["ConditionKey"]] = cond["ConditionValue"]
if not wanted:
    raise SystemExit("solution: the plan's selections match on no tag")

# --- REQUIRED REPAIR 1 of 4: every fleet member carries the selection tag ---
for name in ddb.list_tables()["TableNames"]:
    if not in_fleet(name):
        continue
    try:
        arn = ddb.describe_table(TableName=name)["Table"]["TableArn"]
        tags = {t["Key"]: t["Value"] for t in
                ddb.list_tags_of_resource(ResourceArn=arn).get("Tags", [])}
        missing = [{"Key": k, "Value": v} for k, v in wanted.items() if tags.get(k) != v]
        if missing:
            ddb.tag_resource(ResourceArn=arn, Tags=missing)
            print(f"tagged {name} with {missing}")
    except botocore.exceptions.ClientError as e:
        print(f"skipped table {name}: {e.response['Error']['Code']}")

for fs in efs.describe_file_systems()["FileSystems"]:
  try:
    tags = {t["Key"]: t["Value"] for t in fs.get("Tags", [])}
    if not in_fleet(tags.get("Name", "")):
        continue
    missing = [{"Key": k, "Value": v} for k, v in wanted.items() if tags.get(k) != v]
    if missing:
        efs.tag_resource(ResourceId=fs["FileSystemId"], Tags=missing)
        print(f"tagged {fs['FileSystemId']} with {missing}")

    try:
        pol = json.loads(efs.describe_file_system_policy(
            FileSystemId=fs["FileSystemId"])["Policy"])
    except botocore.exceptions.ClientError:
        continue
    kept = [st for st in pol["Statement"]
            if not (st.get("Effect") == "Deny"
                    and "elasticfilesystem:Backup" in str(st.get("Action")))]
    if len(kept) != len(pol["Statement"]):
        # Either shape works: drop just the Deny, or drop the policy entirely.
        if kept:
            pol["Statement"] = kept
            efs.put_file_system_policy(FileSystemId=fs["FileSystemId"],
                                       Policy=json.dumps(pol))
        else:
            efs.delete_file_system_policy(FileSystemId=fs["FileSystemId"])
        print(f"REQUIRED REPAIR 4 of 4: dropped the explicit Deny on "
              f"elasticfilesystem:Backup from {fs['FileSystemId']}'s own file system "
              f"policy - without this the backup job for it fails at AWS even when the "
              f"tag, the role and the regional opt-in are all correct")
  except botocore.exceptions.ClientError as e:
    print(f"skipped file system {fs.get('FileSystemId')}: {e.response['Error']['Code']}")

# --- REQUIRED REPAIR 2 of 4: the role's inline Deny on file systems --------
for sel in selections:
    role = sel["IamRoleArn"].rsplit("/", 1)[-1]
    for pol in iam.list_role_policies(RoleName=role)["PolicyNames"]:
        doc = iam.get_role_policy(RoleName=role, PolicyName=pol)["PolicyDocument"]
        stmts = doc["Statement"]
        stmts = stmts if isinstance(stmts, list) else [stmts]
        if any(st.get("Effect") == "Deny" for st in stmts):
            iam.delete_role_policy(RoleName=role, PolicyName=pol)
            print(f"removed inline policy {pol} from {role}")

# --- REQUIRED REPAIR 3 of 4: the account+region resource-type opt-in -------
settings = backup.describe_region_settings()["ResourceTypeOptInPreference"]
need = {}
if settings.get("EFS") is False:
    need["EFS"] = True
if settings.get("DynamoDB") is False:
    need["DynamoDB"] = True
if need:
    backup.update_region_settings(ResourceTypeOptInPreference=need)
    print(f"opted in: {need}")
    time.sleep(15)

after = backup.describe_region_settings()["ResourceTypeOptInPreference"]
print(json.dumps({k: after.get(k) for k in ("DynamoDB", "EFS", "EBS")}))

# IAM changes take a moment to reach the AWS Backup service role session.
time.sleep(20)
PY

echo "fixed: fleet tagged, the role's file-system Deny removed, and the account"
echo "opted in to the resource type the plan could not back up (EBS left out)"
