#!/usr/bin/env bash
# Seeds two DynamoDB tables, the shared role dataex-access-role, and three vendor
# integrations (Glue job, CodeBuild project, ECS service in a second region) that each
# assume the role with a stored session policy allowing reads on both tables.
# Records the seeded state in seed_state.json for the checker.
set -euo pipefail
ASSET_DIR="$(cd "$(dirname "$0")/assets" && pwd)"
export ASSET_DIR
python3 - <<'PY'
import json, os, time, uuid, boto3, botocore

REGION = "us-east-1"
MIRROR_REGION = "us-west-2"
ACCT = boto3.client("sts").get_caller_identity()["Account"]

iam = boto3.client("iam")
ddb = boto3.client("dynamodb", region_name=REGION)
glue = boto3.client("glue", region_name=REGION)
cb = boto3.client("codebuild", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
ecs = boto3.client("ecs", region_name=MIRROR_REGION)
ec2 = boto3.client("ec2", region_name=MIRROR_REGION)

CATALOG = "dataex-catalog"
PRICING = "dataex-pricing"
CATALOG_ARN = "arn:aws:dynamodb:%s:%s:table/%s" % (REGION, ACCT, CATALOG)
PRICING_ARN = "arn:aws:dynamodb:%s:%s:table/%s" % (REGION, ACCT, PRICING)
ROLE = "dataex-access-role"
ROLE_ARN = "arn:aws:iam::%s:role/%s" % (ACCT, ROLE)
RECON_ROLE = "dataex-recon-role"
SCOPE_POLICY = "meridian-dataex-scope"
RUNNERS = {"glue": "meridian-export-runner",
           "codebuild": "meridian-feed-runner",
           "ecs": "platform-batch-ops-role"}
GLUE_JOB = "meridian-catalog-export"
CB_PROJECT = "meridian-feed-refresh"
CLUSTER = "meridian-integration"
SERVICE = "meridian-mirror-svc"
FAMILY = "meridian-mirror"
BUCKET = "dataex-scripts-%s" % ACCT
SCRIPT_KEY = "meridian/export.py"
READ_ACTIONS = ["dynamodb:GetItem", "dynamodb:BatchGetItem",
                "dynamodb:Query", "dynamodb:Scan", "dynamodb:DescribeTable"]

BROAD = {"Version": "2012-10-17", "Statement": [
    {"Sid": "ReadSharedTables", "Effect": "Allow", "Action": READ_ACTIONS,
     "Resource": [CATALOG_ARN, PRICING_ARN]}]}
NARROW = {"Version": "2012-10-17", "Statement": [
    {"Sid": "ReadCatalogOnly", "Effect": "Allow", "Action": READ_ACTIONS,
     "Resource": [CATALOG_ARN]}]}


def purge():
    """Remove leftovers from an earlier run."""
    try:
        glue.delete_job(JobName=GLUE_JOB)
    except Exception:
        pass
    try:
        cb.delete_project(name=CB_PROJECT)
    except Exception:
        pass
    # A cluster an earlier run deleted stays describable as INACTIVE for a while, and
    # AWS still answers describe_services / delete_cluster on it; only an ACTIVE
    # cluster holds anything to clean up. Same for task definitions: an INACTIVE
    # revision is already deregistered.
    try:
        live = [c for c in ecs.describe_clusters(clusters=[CLUSTER]).get("clusters", [])
                if c.get("status") == "ACTIVE"]
    except Exception:
        live = []
    if live:
        try:
            for s in ecs.describe_services(cluster=CLUSTER,
                                           services=[SERVICE]).get("services", []):
                for t in s.get("taskSets", []):
                    try:
                        ecs.delete_task_set(cluster=CLUSTER, service=SERVICE,
                                            taskSet=t["id"], force=True)
                    except Exception:
                        pass
        except Exception:
            pass
        try:
            ecs.delete_service(cluster=CLUSTER, service=SERVICE, force=True)
        except Exception:
            pass
        for _ in range(60):
            try:
                found = ecs.describe_services(cluster=CLUSTER,
                                              services=[SERVICE]).get("services", [])
            except Exception:
                break
            if not found or all(s.get("status") == "INACTIVE" for s in found):
                break
            time.sleep(5)
    try:
        for arn in ecs.list_task_definitions(familyPrefix=FAMILY,
                                             status="ACTIVE").get("taskDefinitionArns", []):
            try:
                ecs.deregister_task_definition(taskDefinition=arn)
            except Exception:
                pass
    except Exception:
        pass
    for _ in range(20 if live else 0):
        try:
            ecs.delete_cluster(cluster=CLUSTER)
            break
        except Exception as e:
            if "ClusterNotFoundException" in str(type(e)) or "not found" in str(e).lower():
                break
            time.sleep(5)
    for pname in (SCOPE_POLICY, "platform-batch-ops-policy"):
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
    for r in [ROLE, RECON_ROLE, "meridian-mirror-runner"] + list(RUNNERS.values()):
        try:
            for n in iam.list_role_policies(RoleName=r).get("PolicyNames", []):
                iam.delete_role_policy(RoleName=r, PolicyName=n)
            for a in iam.list_attached_role_policies(RoleName=r).get("AttachedPolicies", []):
                iam.detach_role_policy(RoleName=r, PolicyArn=a["PolicyArn"])
            iam.delete_role(RoleName=r)
        except Exception:
            pass
    for t in (CATALOG, PRICING):
        try:
            ddb.delete_table(TableName=t)
        except Exception:
            pass
    for t in (CATALOG, PRICING):
        try:
            ddb.get_waiter("table_not_exists").wait(TableName=t)
        except Exception:
            pass
    try:
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
            objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
            if objs:
                s3.delete_objects(Bucket=BUCKET, Delete={"Objects": objs})
        s3.delete_bucket(Bucket=BUCKET)
    except Exception:
        pass


purge()

# tables and data
for name, rows in (
    (CATALOG, [("sku-1102", {"name": {"S": "walnut desk 120cm"}, "stock": {"N": "44"}}),
               ("sku-2210", {"name": {"S": "oak shelf"}, "stock": {"N": "17"}}),
               ("sku-3305", {"name": {"S": "steel frame chair"}, "stock": {"N": "260"}})]),
    (PRICING, [("sku-1102", {"unit_cost": {"N": "212.50"}, "floor": {"N": "289.00"}}),
               ("sku-2210", {"unit_cost": {"N": "58.25"}, "floor": {"N": "84.50"}}),
               ("sku-3305", {"unit_cost": {"N": "31.00"}, "floor": {"N": "49.00"}})])):
    ddb.create_table(TableName=name, BillingMode="PAY_PER_REQUEST",
                     AttributeDefinitions=[{"AttributeName": "pk", "AttributeType": "S"}],
                     KeySchema=[{"AttributeName": "pk", "KeyType": "HASH"}])
seeded_items = {}
for name, rows in (
    (CATALOG, [("sku-1102", {"name": {"S": "walnut desk 120cm"}, "stock": {"N": "44"}}),
               ("sku-2210", {"name": {"S": "oak shelf"}, "stock": {"N": "17"}}),
               ("sku-3305", {"name": {"S": "steel frame chair"}, "stock": {"N": "260"}})]),
    (PRICING, [("sku-1102", {"unit_cost": {"N": "212.50"}, "floor": {"N": "289.00"}}),
               ("sku-2210", {"unit_cost": {"N": "58.25"}, "floor": {"N": "84.50"}}),
               ("sku-3305", {"unit_cost": {"N": "31.00"}, "floor": {"N": "49.00"}})])):
    ddb.get_waiter("table_exists").wait(TableName=name)
    seeded_items[name] = {}
    for pk, attrs in rows:
        item = dict(attrs)
        item["pk"] = {"S": pk}
        ddb.put_item(TableName=name, Item=item)
        # Record the stored form, not the input form: DynamoDB canonicalizes numbers.
        seeded_items[name][pk] = ddb.get_item(TableName=name, Key={"pk": {"S": pk}},
                                              ConsistentRead=True)["Item"]

# roles
def make_role(name, trust, tags=None, description=""):
    kwargs = {"RoleName": name, "AssumeRolePolicyDocument": json.dumps(trust),
              "Description": description}
    if tags:
        kwargs["Tags"] = tags
    return iam.create_role(**kwargs)["Role"]["Arn"]


svc_trust = lambda svc: {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"Service": svc}, "Action": "sts:AssumeRole"}]}

RUNNER_ARNS = {}
RUNNER_ARNS["glue"] = make_role(RUNNERS["glue"], svc_trust("glue.amazonaws.com"), None,
                                "Runner for the Meridian catalog export")
RUNNER_ARNS["codebuild"] = make_role(RUNNERS["codebuild"], svc_trust("codebuild.amazonaws.com"),
                                     None, "Runner for the Meridian feed refresh")
RUNNER_ARNS["ecs"] = make_role(RUNNERS["ecs"], svc_trust("ecs-tasks.amazonaws.com"), None,
                               "Shared worker role for platform batch operations")
ops_arn = iam.create_policy(
    PolicyName="platform-batch-ops-policy",
    Description="Baseline grant for platform batch workers",
    PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
        {"Sid": "AssumeDelegated", "Effect": "Allow",
         "Action": "sts:AssumeRole", "Resource": "*"},
        {"Sid": "FetchScripts", "Effect": "Allow", "Action": "s3:GetObject",
         "Resource": "arn:aws:s3:::%s/*" % BUCKET},
        {"Sid": "PullAndLog", "Effect": "Allow",
         "Action": ["ecr:GetAuthorizationToken", "ecr:BatchGetImage",
                    "ecr:GetDownloadUrlForLayer", "logs:CreateLogGroup",
                    "logs:CreateLogStream", "logs:PutLogEvents"],
         "Resource": "*"}]}))["Policy"]["Arn"]
iam.attach_role_policy(RoleName=RUNNERS["ecs"], PolicyArn=ops_arn)
RECON_ARN = make_role(RECON_ROLE, svc_trust("lambda.amazonaws.com"), None,
                      "Internal reconciliation job")

assume_doc = json.dumps({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Action": "sts:AssumeRole", "Resource": ROLE_ARN}]})
for key in ("glue", "codebuild"):
    iam.put_role_policy(RoleName=RUNNERS[key], PolicyName="assume-dataex",
                        PolicyDocument=assume_doc)
iam.put_role_policy(RoleName=RECON_ROLE, PolicyName="assume-dataex",
                    PolicyDocument=assume_doc)
iam.put_role_policy(RoleName=RUNNERS["glue"], PolicyName="job-ops",
                    PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
                        {"Effect": "Allow", "Action": ["s3:GetObject"],
                         "Resource": "arn:aws:s3:::%s/*" % BUCKET},
                        {"Effect": "Allow", "Action": ["logs:CreateLogGroup",
                         "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "*"}]}))
iam.put_role_policy(RoleName=RUNNERS["codebuild"], PolicyName="build-ops",
                    PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
                        {"Effect": "Allow", "Action": ["logs:CreateLogGroup",
                         "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "*"}]}))
trust = {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::%s:root" % ACCT},
     "Action": "sts:AssumeRole"}]}
make_role(ROLE, trust, None, "Shared role vended to data-exchange sessions")
iam.put_role_policy(RoleName=ROLE, PolicyName="dataex-table-read",
                    PolicyDocument=json.dumps(BROAD))

scope_arn = iam.create_policy(
    PolicyName=SCOPE_POLICY, PolicyDocument=json.dumps(BROAD),
    Description="Session scoping applied to Meridian data-exchange sessions",
    Tags=[{"Key": "change", "Value": "INC-3182"},
          {"Key": "status", "Value": "remediated"}])["Policy"]["Arn"]
iam.create_policy_version(PolicyArn=scope_arn, PolicyDocument=json.dumps(NARROW),
                          SetAsDefault=True)

# integration 1: Glue
with open(os.path.join(os.environ["ASSET_DIR"], "export.py"), "rb") as fh:
    script_body = fh.read()
s3.create_bucket(Bucket=BUCKET)
put = s3.put_object(Bucket=BUCKET, Key=SCRIPT_KEY, Body=script_body)
SCRIPT_ETAG = put["ETag"].strip('"')
SCRIPT_LOC = "s3://%s/%s" % (BUCKET, SCRIPT_KEY)

for attempt in range(12):
    try:
        glue.create_job(Name=GLUE_JOB, Role=RUNNER_ARNS["glue"],
                        Command={"Name": "pythonshell", "ScriptLocation": SCRIPT_LOC,
                                 "PythonVersion": "3.9"},
                        MaxCapacity=0.0625,
                        DefaultArguments={"--data-role-arn": ROLE_ARN,
                                          "--session-policy": json.dumps(BROAD),
                                          "--source-table": CATALOG,
                                          "--data-region": REGION},
                        Description="Nightly Meridian catalog export")
        break
    except botocore.exceptions.ClientError:
        if attempt == 11:
            raise
        time.sleep(5)

# integration 2: CodeBuild
BUILDSPEC = """version: 0.2
phases:
  build:
    commands:
      - |
        python3 - <<'EOF'
        import boto3, os
        c = boto3.client("sts").assume_role(
            RoleArn=os.environ["DATA_ROLE_ARN"], RoleSessionName="meridian-feed",
            Policy=os.environ["DATA_SESSION_POLICY"])["Credentials"]
        ddb = boto3.client("dynamodb", region_name=os.environ["DATA_REGION"],
                           aws_access_key_id=c["AccessKeyId"],
                           aws_secret_access_key=c["SecretAccessKey"],
                           aws_session_token=c["SessionToken"])
        rows = ddb.scan(TableName=os.environ["SOURCE_TABLE"])["Items"]
        print("refreshed feed with %d catalog rows" % len(rows))
        EOF
"""
for attempt in range(12):
    try:
        cb.create_project(name=CB_PROJECT,
                          description="Meridian partner feed refresh",
                          source={"type": "NO_SOURCE", "buildspec": BUILDSPEC},
                          artifacts={"type": "NO_ARTIFACTS"},
                          environment={"type": "LINUX_CONTAINER",
                                       "image": "aws/codebuild/standard:7.0",
                                       "computeType": "BUILD_GENERAL1_SMALL",
                                       "environmentVariables": [
                                           {"name": "DATA_ROLE_ARN", "value": ROLE_ARN},
                                           {"name": "DATA_SESSION_POLICY",
                                            "value": json.dumps(BROAD)},
                                           {"name": "SOURCE_TABLE", "value": CATALOG},
                                           {"name": "DATA_REGION", "value": REGION}]},
                          serviceRole=RUNNER_ARNS["codebuild"])
        break
    except botocore.exceptions.ClientError:
        if attempt == 11:
            raise
        time.sleep(5)

# integration 3: ECS mirror
vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
if not vpcs:
    ec2.create_default_vpc()
    for _ in range(30):
        vpcs = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"]
        if vpcs:
            break
        time.sleep(2)
if not vpcs:
    raise SystemExit("no default VPC available in %s" % MIRROR_REGION)
subnets = [s["SubnetId"] for s in ec2.describe_subnets(
    Filters=[{"Name": "vpc-id", "Values": [vpcs[0]["VpcId"]]}])["Subnets"]][:2]

MIRROR_CMD = ("while true; do "
              "CREDS=$(aws sts assume-role --role-arn \"$DATA_ROLE_ARN\" "
              "--role-session-name meridian-mirror --policy \"$DATA_SESSION_POLICY\" "
              "--query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' "
              "--output text); "
              "export AWS_ACCESS_KEY_ID=$(echo \"$CREDS\" | cut -f1); "
              "export AWS_SECRET_ACCESS_KEY=$(echo \"$CREDS\" | cut -f2); "
              "export AWS_SESSION_TOKEN=$(echo \"$CREDS\" | cut -f3); "
              "aws dynamodb scan --table-name \"$SOURCE_TABLE\" --region \"$DATA_REGION\" "
              "--output json > /tmp/mirror.json; sleep 300; done")
IMAGE = "public.ecr.aws/aws-cli/aws-cli:latest"

ecs.create_cluster(clusterName=CLUSTER)
for attempt in range(12):
    try:
        td = ecs.register_task_definition(
            family=FAMILY, requiresCompatibilities=["FARGATE"], networkMode="awsvpc",
            cpu="256", memory="512",
            taskRoleArn=RUNNER_ARNS["ecs"], executionRoleArn=RUNNER_ARNS["ecs"],
            containerDefinitions=[{
                "name": "mirror", "image": IMAGE, "essential": True,
                "entryPoint": ["/bin/sh", "-c"], "command": [MIRROR_CMD],
                "environment": [
                    {"name": "DATA_ROLE_ARN", "value": ROLE_ARN},
                    {"name": "DATA_SESSION_POLICY", "value": json.dumps(BROAD)},
                    {"name": "SOURCE_TABLE", "value": CATALOG},
                    {"name": "DATA_REGION", "value": REGION}]}])
        break
    except botocore.exceptions.ClientError:
        if attempt == 11:
            raise
        time.sleep(5)
ecs.create_service(cluster=CLUSTER, serviceName=SERVICE, desiredCount=1,
                   deploymentController={"type": "EXTERNAL"})
seed_task_set = ecs.create_task_set(
    cluster=CLUSTER, service=SERVICE,
    taskDefinition=td["taskDefinition"]["taskDefinitionArn"],
    launchType="FARGATE",
    networkConfiguration={"awsvpcConfiguration": {
        "subnets": subnets, "assignPublicIp": "ENABLED"}},
    scale={"value": 100.0, "unit": "PERCENT"})["taskSet"]
for attempt in range(12):
    try:
        ecs.update_service_primary_task_set(cluster=CLUSTER, service=SERVICE,
                                            primaryTaskSet=seed_task_set["id"])
        break
    except botocore.exceptions.ClientError:
        if attempt == 11:
            raise
        time.sleep(5)

HOME_CLUSTER = "platform-ops"
HOME_FAMILY = "platform-batch-ops"
HOME_SERVICE = "platform-batch-ops-svc"
ecs_home = boto3.client("ecs", region_name=REGION)
ecs_home.create_cluster(clusterName=HOME_CLUSTER)
for attempt in range(12):
    try:
        home_td = ecs_home.register_task_definition(
            family=HOME_FAMILY, requiresCompatibilities=["EC2"], networkMode="bridge",
            cpu="256", memory="512",
            taskRoleArn=RUNNER_ARNS["ecs"], executionRoleArn=RUNNER_ARNS["ecs"],
            containerDefinitions=[{
                "name": "batch-ops", "image": IMAGE, "essential": True,
                "entryPoint": ["/bin/sh", "-c"],
                "command": ["aws s3 ls > /tmp/inventory.txt; sleep 3600"],
                "environment": [{"name": "REPORT_BUCKET", "value": BUCKET}]}])
        break
    except botocore.exceptions.ClientError:
        if attempt == 11:
            raise
        time.sleep(5)
for _try in range(2):
    try:
        ecs_home.create_service(cluster=HOME_CLUSTER, serviceName=HOME_SERVICE,
                                taskDefinition=home_td["taskDefinition"]["taskDefinitionArn"],
                                launchType="EC2", desiredCount=0)
        break
    except botocore.exceptions.ClientError:
        if _try:
            raise
        HOME_SERVICE = "%s-%s" % (HOME_SERVICE, uuid.uuid4().hex[:6])


def snapshot_table(name):
    """The configuration fields the task says stay as they are, minus volatile counters."""
    t = ddb.describe_table(TableName=name)["Table"]
    try:
        pitr = ddb.describe_continuous_backups(TableName=name)[
            "ContinuousBackupsDescription"]["PointInTimeRecoveryDescription"][
            "PointInTimeRecoveryStatus"]
    except Exception:
        pitr = "DISABLED"
    return {
        "billing_mode": (t.get("BillingModeSummary") or {}).get("BillingMode"),
        "deletion_protection": bool(t.get("DeletionProtectionEnabled")),
        "key_schema": t.get("KeySchema"),
        "attribute_definitions": t.get("AttributeDefinitions"),
        "sse": (t.get("SSEDescription") or {}).get("Status"),
        "stream": (t.get("StreamSpecification") or {}).get("StreamEnabled", False),
        "table_class": (t.get("TableClassSummary") or {}).get("TableClass"),
        "gsi": sorted(i["IndexName"] for i in t.get("GlobalSecondaryIndexes", []) or []),
        "lsi": sorted(i["IndexName"] for i in t.get("LocalSecondaryIndexes", []) or []),
        "pitr": pitr,
    }


table_config = {CATALOG: snapshot_table(CATALOG), PRICING: snapshot_table(PRICING)}

state = {
    "region": REGION,
    "mirror_region": MIRROR_REGION,
    "account": ACCT,
    "catalog_table": CATALOG, "pricing_table": PRICING,
    "catalog_arn": CATALOG_ARN, "pricing_arn": PRICING_ARN,
    "role": ROLE, "role_arn": ROLE_ARN,
    "recon_role": RECON_ROLE, "recon_role_arn": RECON_ARN,
    "scope_policy_arn": scope_arn,
    "runners": RUNNERS,
    "glue_job": GLUE_JOB,
    "script_bucket": BUCKET, "script_key": SCRIPT_KEY, "script_etag": SCRIPT_ETAG,
    "script_location": SCRIPT_LOC,
    "codebuild_project": CB_PROJECT, "buildspec": BUILDSPEC,
    "ecs_cluster": CLUSTER, "ecs_service": SERVICE, "ecs_family": FAMILY,
    "container_name": "mirror", "container_command": [MIRROR_CMD], "container_image": IMAGE,
    "seed_task_set_id": seed_task_set["id"],
    "trust_doc": trust,
    "broad_doc": BROAD,
    "items": seeded_items,
    "table_config": table_config,
    "home_cluster": HOME_CLUSTER, "home_service": HOME_SERVICE, "home_family": HOME_FAMILY,
}
out = os.path.join(os.environ.get("TASK_STATE_DIR", os.path.dirname(os.path.abspath(__file__))),
                   "seed_state.json")
with open(out, "w") as fh:
    json.dump(state, fh, indent=2)
print("seeded tables=%s,%s glue=%s codebuild=%s ecs=%s/%s in %s"
      % (CATALOG, PRICING, GLUE_JOB, CB_PROJECT, CLUSTER, SERVICE, MIRROR_REGION))
PY
