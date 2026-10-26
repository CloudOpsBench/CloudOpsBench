#!/usr/bin/env bash
# Best-effort removal of everything setup.sh created. Never fails.
set -uo pipefail
python3 - <<'PY' || true
import time, boto3

REGION = "us-east-1"
MIRROR_REGION = "us-west-2"
try:
    ACCT = boto3.client("sts").get_caller_identity()["Account"]
except Exception:
    raise SystemExit(0)

iam = boto3.client("iam")
ddb = boto3.client("dynamodb", region_name=REGION)
glue = boto3.client("glue", region_name=REGION)
cb = boto3.client("codebuild", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
ecs = boto3.client("ecs", region_name=MIRROR_REGION)
ecs_home = boto3.client("ecs", region_name=REGION)
try:
    for _svc in ecs_home.list_services(cluster="platform-ops").get("serviceArns", []):
        try:
            ecs_home.delete_service(cluster="platform-ops", service=_svc, force=True)
        except Exception:
            pass
except Exception:
    pass
try:
    for _arn in ecs_home.list_task_definitions(
            familyPrefix="platform-batch-ops", status="ACTIVE").get("taskDefinitionArns", []):
        try:
            ecs_home.deregister_task_definition(taskDefinition=_arn)
        except Exception:
            pass
except Exception:
    pass
for _ in range(6):          # delete_service returns before the service finishes draining
    try:
        ecs_home.delete_cluster(cluster="platform-ops")
        break
    except Exception:
        time.sleep(5)

try:
    glue.delete_job(JobName="meridian-catalog-export")
except Exception:
    pass
try:
    cb.delete_project(name="meridian-feed-refresh")
except Exception:
    pass
try:
    for s in ecs.describe_services(cluster="meridian-integration",
                                   services=["meridian-mirror-svc"]).get("services", []):
        for t in s.get("taskSets", []):
            try:
                ecs.delete_task_set(cluster="meridian-integration",
                                    service="meridian-mirror-svc", taskSet=t["id"],
                                    force=True)
            except Exception:
                pass
except Exception:
    pass
try:
    ecs.delete_service(cluster="meridian-integration", service="meridian-mirror-svc",
                       force=True)
except Exception:
    pass
for st in ("ACTIVE", "INACTIVE"):
    try:
        for arn in ecs.list_task_definitions(familyPrefix="meridian-mirror",
                                             status=st).get("taskDefinitionArns", []):
            try:
                ecs.deregister_task_definition(taskDefinition=arn)
            except Exception:
                pass
    except Exception:
        pass
for _ in range(20):
    try:
        ecs.delete_cluster(cluster="meridian-integration")
        break
    except Exception as e:
        if "not found" in str(e).lower() or "ClusterNotFound" in str(e):
            break
        time.sleep(5)
for pname in ("meridian-dataex-scope", "platform-batch-ops-policy"):
    arn = "arn:aws:iam::%s:policy/%s" % (ACCT, pname)
    try:
        for e in iam.list_entities_for_policy(PolicyArn=arn).get("PolicyRoles", []):
            iam.detach_role_policy(RoleName=e["RoleName"], PolicyArn=arn)
        for v in iam.list_policy_versions(PolicyArn=arn)["Versions"]:
            if not v["IsDefaultVersion"]:
                iam.delete_policy_version(PolicyArn=arn, VersionId=v["VersionId"])
        iam.delete_policy(PolicyArn=arn)
    except Exception:
        pass
for r in ("dataex-access-role", "dataex-recon-role", "meridian-export-runner",
          "meridian-feed-runner", "meridian-mirror-runner", "platform-batch-ops-role"):
    try:
        for n in iam.list_role_policies(RoleName=r).get("PolicyNames", []):
            iam.delete_role_policy(RoleName=r, PolicyName=n)
        for a in iam.list_attached_role_policies(RoleName=r).get("AttachedPolicies", []):
            iam.detach_role_policy(RoleName=r, PolicyArn=a["PolicyArn"])
        iam.delete_role(RoleName=r)
    except Exception:
        pass
for t in ("dataex-catalog", "dataex-pricing"):
    try:
        ddb.delete_table(TableName=t)
    except Exception:
        pass
bkt = "dataex-scripts-%s" % ACCT
try:
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bkt):
        objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if objs:
            s3.delete_objects(Bucket=bkt, Delete={"Objects": objs})
    s3.delete_bucket(Bucket=bkt)
except Exception:
    pass
print("teardown done")
PY
exit 0
