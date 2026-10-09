#!/usr/bin/env bash
# Removes the backup plan, vault, recovery points, fleet resources and role that
# setup created, and restores the account's AWS Backup opt-in settings.
set -uo pipefail
export MSYS_NO_PATHCONV=1

if [ -f seed_state.json ]; then
  SFX=$(python3 -c "import json; print(json.load(open('seed_state.json'))['suffix'])" 2>/dev/null) || SFX=""
fi
[ -n "${SFX:-}" ] || { [ -f .sfx ] && SFX=$(cat .sfx); }
[ -n "${SFX:-}" ] || exit 0

python3 - "$SFX" <<'PY' || true
import json
import sys
import time

import boto3
import botocore.exceptions

SFX = sys.argv[1]
REGION = "us-east-1"
backup = boto3.client("backup", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
efs = boto3.client("efs", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
sts = boto3.client("sts", region_name=REGION)
iam = boto3.client("iam")

VAULT = f"vera-vault-{SFX}"
PLAN = f"vera-nightly-{SFX}"
ROLE = f"vera-backup-role-{SFX}"


def quiet(fn, *a, **k):
    try:
        return fn(*a, **k)
    except Exception:
        return None


# a job still running would write a recovery point after the vault sweep below
for job in (quiet(backup.list_backup_jobs, ByBackupVaultName=VAULT, ByState="RUNNING")
            or {}).get("BackupJobs", []):
    quiet(backup.stop_backup_job, BackupJobId=job["BackupJobId"])
if (quiet(backup.list_backup_jobs, ByBackupVaultName=VAULT, ByState="RUNNING")
        or {}).get("BackupJobs"):
    time.sleep(20)


def listed(op, key, **kw):
    """Every item of a paginated AWS Backup listing ([] when the call fails)."""
    try:
        return [item for page in backup.get_paginator(op).paginate(**kw) for item in page.get(key, [])]
    except Exception:
        return []


# the plan and its selections
for plan in listed("list_backup_plans", "BackupPlansList"):
    if plan.get("BackupPlanName") == PLAN:
        for sel in listed("list_backup_selections", "BackupSelectionsList",
                          BackupPlanId=plan["BackupPlanId"]):
            quiet(backup.delete_backup_selection, BackupPlanId=plan["BackupPlanId"],
                  SelectionId=sel["SelectionId"])
        quiet(backup.delete_backup_plan, BackupPlanId=plan["BackupPlanId"])

# the vault sweep: every recovery point (check.py's backup jobs write them), then the
# vault. Recovery points are deleted asynchronously, so wait until the vault lists none
# and delete it once: a vault still holding points refuses (InvalidRequestException).
for _ in range(18):
    points = listed("list_recovery_points_by_backup_vault", "RecoveryPoints", BackupVaultName=VAULT)
    if not points:
        break
    for rp in points:
        if rp.get("Status") != "DELETING":
            quiet(backup.delete_recovery_point, BackupVaultName=VAULT,
                  RecoveryPointArn=rp["RecoveryPointArn"])
    time.sleep(10)
quiet(backup.delete_backup_vault, BackupVaultName=VAULT)

# the fleet: both file systems (by their creation tokens) and both tables
for token in (f"vera-archive-{SFX}", f"vera-exports-{SFX}"):
    for fs in (quiet(efs.describe_file_systems, CreationToken=token) or {}).get("FileSystems", []):
        for mt in (quiet(efs.describe_mount_targets, FileSystemId=fs["FileSystemId"])
                   or {}).get("MountTargets", []):
            quiet(efs.delete_mount_target, MountTargetId=mt["MountTargetId"])
        for _ in range(12):  # mount targets, or a stopped backup job, release it shortly
            if quiet(efs.delete_file_system, FileSystemId=fs["FileSystemId"]) is not None:
                break
            time.sleep(10)
for table in (f"vera-orders-{SFX}", f"vera-audit-{SFX}"):
    quiet(ddb.delete_table, TableName=table)
for table in (f"vera-orders-{SFX}", f"vera-audit-{SFX}"):  # gone, not just DELETING
    quiet(ddb.get_waiter("table_not_exists").wait, TableName=table,
          WaiterConfig={"Delay": 5, "MaxAttempts": 36})

try:
    acct = sts.get_caller_identity()["Account"]
except Exception:
    acct = ""
bucket = f"vera-scratch-{acct}-{SFX}" if acct else None
if bucket:
    objs = (quiet(s3.list_object_versions, Bucket=bucket) or {})
    for key in ("Versions", "DeleteMarkers"):
        for o in objs.get(key, []):
            quiet(s3.delete_object, Bucket=bucket, Key=o["Key"], VersionId=o["VersionId"])
    quiet(s3.delete_bucket, Bucket=bucket)

for pol in (quiet(iam.list_role_policies, RoleName=ROLE) or {}).get("PolicyNames", []):
    quiet(iam.delete_role_policy, RoleName=ROLE, PolicyName=pol)
for att in (quiet(iam.list_attached_role_policies, RoleName=ROLE)
            or {}).get("AttachedPolicies", []):
    quiet(iam.detach_role_policy, RoleName=ROLE, PolicyArn=att["PolicyArn"])
quiet(iam.delete_role, RoleName=ROLE)

# The opt-in map is account-wide: put back what setup found (it saved the map before
# seeding the gap); without that record, the way an untouched account has it.
before = None
try:
    with open(".optin_before.json") as fh:
        before = {k: v for k, v in json.load(fh).items() if k in ("EFS", "S3", "DynamoDB")}
except Exception:
    pass
quiet(backup.update_region_settings,
      ResourceTypeOptInPreference=before or {"EFS": True, "S3": True, "DynamoDB": True})
PY

rm -f .sfx seed_state.json .optin_before.json
exit 0
