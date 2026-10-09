#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

SFX="${RANDOM}${RANDOM}"
echo "$SFX" > .sfx

python3 - "$SFX" <<'PY'
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
iam = boto3.client("iam")
acct = boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]

VAULT = f"vera-vault-{SFX}"
PLAN = f"vera-nightly-{SFX}"
ROLE = f"vera-backup-role-{SFX}"
ROLE_ARN = f"arn:aws:iam::{acct}:role/{ROLE}"
T_ORDERS = f"vera-orders-{SFX}"
T_AUDIT = f"vera-audit-{SFX}"
FS_TOKEN = f"vera-archive-{SFX}"
FS2_TOKEN = f"vera-exports-{SFX}"
TAG_KEY = "backup"
TAG_VALUE = "nightly"


def retry(fn, tries=10, delay=6, ok_codes=()):
    last = None
    for _ in range(tries):
        try:
            return fn()
        except botocore.exceptions.ClientError as e:
            code = e.response["Error"]["Code"]
            if code in ok_codes:
                return None
            last = e
            time.sleep(delay)
    raise last


def settles(read, want, label, tries=45, delay=4, transient=()):
    """Poll a just-created resource until it reads `want`.

    EC2 and EFS are both eventually consistent right after a create call: a
    describe on an id the create call just returned can answer NotFound for a
    few seconds. The botocore waiters treat that as terminal, which is what
    broke v2 on the platform while four local runs passed, so every post-create
    poll in this setup tolerates the not-found window itself.
    """
    for _ in range(tries):
        try:
            if read() == want:
                return
        except botocore.exceptions.ClientError as e:
            if e.response["Error"]["Code"] not in transient:
                raise
        time.sleep(delay)
    raise SystemExit(f"setup: {label} never reached {want}")



SCRATCH = f"vera-scratch-{acct}-{SFX}"
s3.create_bucket(Bucket=SCRATCH)
s3.put_bucket_tagging(Bucket=SCRATCH, Tagging={"TagSet": [
    {"Key": "Name", "Value": f"vera-scratch-{SFX}"},
    {"Key": TAG_KEY, "Value": TAG_VALUE},
    {"Key": "fleet", "Value": "vera"}]})
SCRATCH_ARN = f"arn:aws:s3:::{SCRATCH}"

# --- IAM role the backup selection runs as -----------------------------------
trust = {"Version": "2012-10-17", "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "backup.amazonaws.com"},
    "Action": "sts:AssumeRole"}]}
iam.create_role(RoleName=ROLE, AssumeRolePolicyDocument=json.dumps(trust),
                Description="Runs the nightly vera backup plan")
for arn in ("arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
            "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"):
    iam.attach_role_policy(RoleName=ROLE, PolicyArn=arn)

iam.put_role_policy(
    RoleName=ROLE, PolicyName="deny-file-system-access",
    PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [{
        "Sid": "NoFileSystems",
        "Effect": "Deny",
        "Action": "elasticfilesystem:*",
        "Resource": "*"}]}))

# --- fleet resources ----------------------------------------------------------
for name in (T_ORDERS, T_AUDIT):
    ddb.create_table(TableName=name,
                     AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
                     KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
                     BillingMode="PAY_PER_REQUEST")
for name in (T_ORDERS, T_AUDIT):
    ddb.get_waiter("table_exists").wait(TableName=name)

tables = {}
for name in (T_ORDERS, T_AUDIT):
    tables[name] = ddb.describe_table(TableName=name)["Table"]["TableArn"]

# Fault 1: only orders carries the tag the selection matches on.
retry(lambda: ddb.tag_resource(ResourceArn=tables[T_ORDERS],
                 Tags=[{"Key": TAG_KEY, "Value": TAG_VALUE},
                       {"Key": "fleet", "Value": "vera"}]))
retry(lambda: ddb.tag_resource(ResourceArn=tables[T_AUDIT],
                               Tags=[{"Key": "fleet", "Value": "vera"}]))

def make_fs(token, name):
    fs = efs.create_file_system(
        CreationToken=token, PerformanceMode="generalPurpose", Encrypted=True,
        Tags=[{"Key": "Name", "Value": name},
              {"Key": TAG_KEY, "Value": TAG_VALUE},
              {"Key": "fleet", "Value": "vera"}])
    settles(lambda: efs.describe_file_systems(
                FileSystemId=fs["FileSystemId"])["FileSystems"][0]["LifeCycleState"],
            "available", f"file system {fs['FileSystemId']}",
            transient=("FileSystemNotFound",))
    return fs["FileSystemId"], fs["FileSystemArn"]


FS_ID, FS_ARN = make_fs(FS_TOKEN, f"vera-archive-{SFX}")
FS2_ID, FS2_ARN = make_fs(FS2_TOKEN, f"vera-exports-{SFX}")

retry(lambda: efs.put_file_system_policy(
    FileSystemId=FS2_ID,
    Policy=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Sid": "LedgerMounts",
         "Effect": "Allow",
         "Principal": {"AWS": f"arn:aws:iam::{acct}:root"},
         "Action": "elasticfilesystem:*",
         "Resource": "*"},
        {"Sid": "NoCopiesOffThisFileSystem",
         "Effect": "Deny",
         "Principal": {"AWS": "*"},
         "Action": "elasticfilesystem:Backup",
         "Resource": "*"}]})))


# --- vault, plan, tag-based selection -----------------------------------------
backup.create_backup_vault(BackupVaultName=VAULT,
                           BackupVaultTags={"fleet": "vera"})

plan = retry(lambda: backup.create_backup_plan(BackupPlan={
    "BackupPlanName": PLAN,
    "Rules": [{
        "RuleName": "nightly",
        "TargetBackupVaultName": VAULT,
        "ScheduleExpression": "cron(0 5 * * ? *)",
        "StartWindowMinutes": 60,
        "CompletionWindowMinutes": 180,
        "Lifecycle": {"DeleteAfterDays": 35},
    }]}))
PLAN_ID = plan["BackupPlanId"]

sel = retry(lambda: backup.create_backup_selection(
    BackupPlanId=PLAN_ID,
    BackupSelection={
        "SelectionName": "vera-fleet",
        "IamRoleArn": ROLE_ARN,
        "ListOfTags": [{"ConditionType": "STRINGEQUALS",
                        "ConditionKey": TAG_KEY,
                        "ConditionValue": TAG_VALUE}],
    }))
SELECTION_ID = sel["SelectionId"]

# The opt-in map is account-wide: record what the account had, so teardown can put it back.
with open(".optin_before.json", "w") as fh:
    json.dump(backup.describe_region_settings()["ResourceTypeOptInPreference"], fh)
backup.update_region_settings(
    ResourceTypeOptInPreference={"EFS": False, "S3": False, "DynamoDB": True})
time.sleep(5)
settings = backup.describe_region_settings()["ResourceTypeOptInPreference"]
for want, key in ((False, "EFS"), (False, "S3"), (True, "DynamoDB")):
    if settings.get(key) is not want:
        raise SystemExit(f"setup: opt-in for {key} seeded as {settings.get(key)}, wanted {want}")

# --- prove the seeded state is the broken one --------------------------------
try:
    backup.start_backup_job(BackupVaultName=VAULT, ResourceArn=FS_ARN, IamRoleArn=ROLE_ARN)
    raise SystemExit("setup: a file-system backup was accepted, so the opt-in gap is absent")
except botocore.exceptions.ClientError as e:
    if "not opted in" not in e.response["Error"]["Message"]:
        raise SystemExit(f"setup: file-system backup refused for the wrong reason: "
                         f"{e.response['Error']['Message']}")

policy = json.loads(efs.describe_file_system_policy(FileSystemId=FS2_ID)["Policy"])
denies = [st for st in policy["Statement"]
          if st["Effect"] == "Deny" and "elasticfilesystem:Backup" in str(st["Action"])]
if not denies:
    raise SystemExit(f"setup: {FS2_ID} carries no Deny on elasticfilesystem:Backup")

points = backup.list_recovery_points_by_backup_vault(
    BackupVaultName=VAULT)["RecoveryPoints"]
if points:
    raise SystemExit(f"setup: vault {VAULT} already holds {len(points)} recovery points")

scratch_created = [b["CreationDate"].isoformat() for b in s3.list_buckets()["Buckets"]
                   if b["Name"] == SCRATCH][0]
vault_created = backup.describe_backup_vault(
    BackupVaultName=VAULT)["CreationDate"].isoformat()
table_ids = {n: ddb.describe_table(TableName=n)["Table"]["TableId"]
             for n in (T_ORDERS, T_AUDIT)}

seed = {
    "suffix": SFX,
    "region": REGION,
    "account": acct,
    "vault": VAULT,
    "plan_name": PLAN,
    "plan_id": PLAN_ID,
    "selection_id": SELECTION_ID,
    "role_name": ROLE,
    "role_arn": ROLE_ARN,
    "tag_key": TAG_KEY,
    "tag_value": TAG_VALUE,
    "table_orders": T_ORDERS,
    "table_audit": T_AUDIT,
    "table_arns": tables,
    "table_ids": table_ids,
    "vault_created": vault_created,
    "fs_id": FS_ID,
    "fs_arn": FS_ARN,
    "fs2_id": FS2_ID,
    "fs2_arn": FS2_ARN,
    "scratch_bucket": SCRATCH,
    "scratch_created": scratch_created,
    "protected": [tables[T_ORDERS], tables[T_AUDIT], FS_ARN, FS2_ARN],
    "excluded": SCRATCH_ARN,
}
with open("seed_state.json", "w") as fh:
    json.dump(seed, fh, indent=2)
PY

echo "seeded $SFX: plan vera-nightly-$SFX selects backup=nightly into"
echo "vera-vault-$SFX. The audit table is untagged, the selection's role"
echo "denies elasticfilesystem:*, and AWS Backup in us-east-1 is opted out of"
echo "EFS (killer) and of S3 (which is what keeps the scratch bucket out)."
echo "vera-exports-$SFX also denies elasticfilesystem:Backup in its own file"
echo "system policy, which only bites once the opt-in is fixed."
