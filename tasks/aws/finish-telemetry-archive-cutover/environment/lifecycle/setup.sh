#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import boto3, json, os, time, uuid

REGION = "us-east-1"
EDGE = "us-west-2"
ACCT = boto3.client("sts").get_caller_identity()["Account"]
SFX = uuid.uuid4().hex[:8]

iam = boto3.client("iam")
s3 = boto3.client("s3", region_name=REGION)
s3e = boto3.client("s3", region_name=EDGE)
fh = boto3.client("firehose", region_name=REGION)
ds = boto3.client("datasync", region_name=REGION)
ssm = boto3.client("ssm", region_name=REGION)

PREFIXES = ("telemetry-archive-legacy-", "telemetry-archive-2026-", "telemetry-ingest-",
            "telemetry-compliance-", "edge-telemetry-ingest-")
REPL_ROLE = "telemetry-archive-replication-role"
FH_ROLE = "telemetry-archive-firehose-role"
DS_ROLE = "telemetry-archive-datasync-role"


def purge():
    """Remove leftovers from an earlier run. The lane nukes state; a dev account does not."""
    try:
        for name in fh.list_delivery_streams(Limit=100)["DeliveryStreamNames"]:
            if name == "telemetry-raw-stream":
                fh.delete_delivery_stream(DeliveryStreamName=name)
    except Exception:
        pass
    for reg in (REGION, EDGE):
        d = boto3.client("datasync", region_name=reg)
        try:
            for t in d.list_tasks(MaxResults=100).get("Tasks", []):
                if t.get("Name") in ("partner-drop-nightly", "analytics-export-daily"):
                    d.delete_task(TaskArn=t["TaskArn"])
            for l in d.list_locations(MaxResults=100).get("Locations", []):
                if any(p in l.get("LocationUri", "") for p in PREFIXES):
                    d.delete_location(LocationArn=l["LocationArn"])
        except Exception:
            pass
    try:
        buckets = [b["Name"] for b in s3.list_buckets()["Buckets"]]
    except Exception:
        buckets = []
    for b in buckets:
        if not b.startswith(PREFIXES):
            continue
        try:
            loc = s3.get_bucket_location(Bucket=b).get("LocationConstraint") or "us-east-1"
            c = boto3.client("s3", region_name=loc)
            for page in c.get_paginator("list_object_versions").paginate(Bucket=b):
                objs = [{"Key": o["Key"], "VersionId": o["VersionId"]}
                        for o in page.get("Versions", []) + page.get("DeleteMarkers", [])]
                if objs:
                    c.delete_objects(Bucket=b, Delete={"Objects": objs})
            c.delete_bucket(Bucket=b)
        except Exception:
            pass
    e = boto3.client("ec2", region_name=EDGE)
    try:
        ids = [f["FlowLogId"] for f in e.describe_flow_logs()["FlowLogs"]
               if any(p in f.get("LogDestination", "") for p in PREFIXES)]
        if ids:
            e.delete_flow_logs(FlowLogIds=ids)
        for v in e.describe_vpcs(Filters=[{"Name": "tag:Name",
                                           "Values": ["edge-telemetry-vpc"]}])["Vpcs"]:
            e.delete_vpc(VpcId=v["VpcId"])
    except Exception:
        pass
    try:
        boto3.client("athena", region_name=EDGE).delete_work_group(
            WorkGroup="telemetry-adhoc", RecursiveDeleteOption=True)
    except Exception:
        pass
    for r in (REPL_ROLE, FH_ROLE, DS_ROLE):
        try:
            for p in iam.list_role_policies(RoleName=r)["PolicyNames"]:
                iam.delete_role_policy(RoleName=r, PolicyName=p)
            iam.delete_role(RoleName=r)
        except Exception:
            pass


def make_role(name, service):
    trust = {"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": service}, "Action": "sts:AssumeRole"}]}
    try:
        iam.create_role(RoleName=name, AssumeRolePolicyDocument=json.dumps(trust))
    except iam.exceptions.EntityAlreadyExistsException:
        iam.update_assume_role_policy(RoleName=name, PolicyDocument=json.dumps(trust))
    iam.put_role_policy(RoleName=name, PolicyName="access", PolicyDocument=json.dumps(
        {"Version": "2012-10-17", "Statement": [
            {"Effect": "Allow", "Action": "s3:*", "Resource": "*"},
            {"Effect": "Allow", "Action": ["logs:PutLogEvents", "logs:CreateLogStream"],
             "Resource": "*"}]}))
    return "arn:aws:iam::%s:role/%s" % (ACCT, name)


def make_bucket(client, name, region):
    if region == "us-east-1":
        client.create_bucket(Bucket=name)
    else:
        client.create_bucket(Bucket=name,
                             CreateBucketConfiguration={"LocationConstraint": region})
    client.put_bucket_versioning(Bucket=name,
                                 VersioningConfiguration={"Status": "Enabled"})
    return name


purge()

LEGACY = "telemetry-archive-legacy-%s-%s" % (ACCT, SFX)
NEW = "telemetry-archive-2026-%s-%s" % (ACCT, SFX)
INGEST = "telemetry-ingest-%s-%s" % (ACCT, SFX)
COMPLIANCE = "telemetry-compliance-%s-%s" % (ACCT, SFX)
EDGE_INGEST = "edge-telemetry-ingest-%s-%s" % (ACCT, SFX)

make_bucket(s3, LEGACY, REGION)
make_bucket(s3, NEW, REGION)
make_bucket(s3, INGEST, REGION)
make_bucket(s3, COMPLIANCE, REGION)
make_bucket(s3e, EDGE_INGEST, EDGE)

repl_arn = make_role(REPL_ROLE, "s3.amazonaws.com")
fh_arn = make_role(FH_ROLE, "firehose.amazonaws.com")
ds_arn = make_role(DS_ROLE, "datasync.amazonaws.com")

# The retired archive already holds history. It is under audit hold and must survive intact.
LEGACY_KEYS = ["raw/2026/07/%02d/batch.json" % i for i in range(1, 6)] + \
              ["partner/2026/07/manifest-%d.csv" % i for i in range(1, 4)]
for k in LEGACY_KEYS:
    s3.put_object(Bucket=LEGACY, Key=k, Body=b'{"telemetry": "archived"}')
# The replacement already looks live: copied history sits under both prefixes.
for k in LEGACY_KEYS:
    s3.put_object(Bucket=NEW, Key=k, Body=b'{"telemetry": "archived"}')

time.sleep(12)  # IAM propagation before S3/DataSync/Firehose validate the roles

# --- writer 1: replication on the in-region ingest bucket -------------------------------
INGEST_REPL = {
    "Role": repl_arn,
    "Rules": [
        {"ID": "archive-feed", "Priority": 1, "Status": "Enabled",
         "Filter": {"Prefix": "telemetry/"},
         "DeleteMarkerReplication": {"Status": "Disabled"},
         "Destination": {"Bucket": "arn:aws:s3:::" + LEGACY, "StorageClass": "STANDARD"}},
        {"ID": "compliance-feed", "Priority": 2, "Status": "Enabled",
         "Filter": {"Prefix": "telemetry/"},
         "DeleteMarkerReplication": {"Status": "Disabled"},
         "Destination": {"Bucket": "arn:aws:s3:::" + COMPLIANCE,
                         "StorageClass": "STANDARD_IA"}},
    ],
}
iam.put_role_policy(RoleName=REPL_ROLE, PolicyName="access", PolicyDocument=json.dumps(
    {"Version": "2012-10-17", "Statement": [
        {"Sid": "ReadSources", "Effect": "Allow",
         "Action": ["s3:GetReplicationConfiguration", "s3:ListBucket"],
         "Resource": ["arn:aws:s3:::" + INGEST, "arn:aws:s3:::" + EDGE_INGEST]},
        {"Sid": "ReadSourceObjects", "Effect": "Allow",
         "Action": ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl",
                    "s3:GetObjectVersionTagging"],
         "Resource": ["arn:aws:s3:::%s/*" % INGEST, "arn:aws:s3:::%s/*" % EDGE_INGEST]},
        {"Sid": "WriteArchiveAndCompliance", "Effect": "Allow",
         "Action": ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"],
         "Resource": ["arn:aws:s3:::%s/*" % LEGACY, "arn:aws:s3:::%s/*" % COMPLIANCE]}]}))
time.sleep(10)

s3.put_bucket_replication(Bucket=INGEST, ReplicationConfiguration=INGEST_REPL)

# --- writer 2: replication on the ingest bucket in the other region ---------------------
EDGE_REPL = {
    "Role": repl_arn,
    "Rules": [
        {"ID": "edge-archive-feed", "Priority": 1, "Status": "Enabled",
         "Filter": {"Prefix": "telemetry/"},
         "DeleteMarkerReplication": {"Status": "Disabled"},
         "Destination": {"Bucket": "arn:aws:s3:::" + LEGACY, "StorageClass": "STANDARD"}},
        {"ID": "edge-compliance-feed", "Priority": 2, "Status": "Enabled",
         "Filter": {"Prefix": "telemetry/"},
         "DeleteMarkerReplication": {"Status": "Disabled"},
         "Destination": {"Bucket": "arn:aws:s3:::" + COMPLIANCE,
                         "StorageClass": "STANDARD_IA"}},
    ],
}
s3e.put_bucket_replication(Bucket=EDGE_INGEST, ReplicationConfiguration=EDGE_REPL)

# --- writer 3: the raw telemetry delivery stream ----------------------------------------
fh.create_delivery_stream(
    DeliveryStreamName="telemetry-raw-stream",
    DeliveryStreamType="DirectPut",
    ExtendedS3DestinationConfiguration={
        "RoleARN": fh_arn,
        "BucketARN": "arn:aws:s3:::" + LEGACY,
        "Prefix": "raw/",
        "BufferingHints": {"SizeInMBs": 1, "IntervalInSeconds": 60},
        "CompressionFormat": "UNCOMPRESSED",
    })

# --- writer 4: the nightly partner sync -------------------------------------------------
SCHEDULE = "cron(0 3 * * ? *)"
EXCLUDES = [{"FilterType": "SIMPLE_PATTERN", "Value": "/staging/*|*.partial"}]


def location(client, bucket, subdir):
    for _ in range(8):
        try:
            return client.create_location_s3(
                Subdirectory=subdir, S3BucketArn="arn:aws:s3:::" + bucket,
                S3Config={"BucketAccessRoleArn": ds_arn})["LocationArn"]
        except Exception:
            time.sleep(8)
    raise SystemExit("could not create DataSync location for " + bucket)


src = location(ds, INGEST, "/partner/")
dst_legacy = location(ds, LEGACY, "/partner/")
partner_task = ds.create_task(
    SourceLocationArn=src, DestinationLocationArn=dst_legacy,
    Name="partner-drop-nightly", Schedule={"ScheduleExpression": SCHEDULE},
    Excludes=EXCLUDES)["TaskArn"]

# --- already cut over, and not part of the work: leave alone ----------------------------
an_src = location(ds, INGEST, "/analytics/")
an_dst = location(ds, NEW, "/analytics/")
analytics_task = ds.create_task(
    SourceLocationArn=an_src, DestinationLocationArn=an_dst,
    Name="analytics-export-daily", Schedule={"ScheduleExpression": "cron(0 5 * * ? *)"},
    Excludes=[{"FilterType": "SIMPLE_PATTERN", "Value": "*.tmp"}])["TaskArn"]

# --- writer 5: a flow log in the other region, writing straight into the retired bucket --
ec2e = boto3.client("ec2", region_name=EDGE)
vpc = ec2e.create_vpc(CidrBlock="10.77.0.0/16")["Vpc"]["VpcId"]
ec2e.create_tags(Resources=[vpc], Tags=[
    {"Key": "Name", "Value": "edge-telemetry-vpc"},
    {"Key": "archive-cutover", "Value": "complete"}])
FLOW_PREFIX = "flow/"
flow = ec2e.create_flow_logs(
    ResourceIds=[vpc], ResourceType="VPC", TrafficType="ALL",
    LogDestinationType="s3",
    LogDestination="arn:aws:s3:::%s/%s" % (LEGACY, FLOW_PREFIX))["FlowLogIds"][0]

LOG_DELIVERY = lambda b: json.dumps({
    "Version": "2012-10-17", "Id": "AWSLogDeliveryWrite20150319", "Statement": [
        {"Sid": "AWSLogDeliveryWrite", "Effect": "Allow",
         "Principal": {"Service": "delivery.logs.amazonaws.com"},
         "Action": "s3:PutObject", "Resource": "arn:aws:s3:::%s/*" % b},
        {"Sid": "AWSLogDeliveryAclCheck", "Effect": "Allow",
         "Principal": {"Service": "delivery.logs.amazonaws.com"},
         "Action": "s3:GetBucketAcl", "Resource": "arn:aws:s3:::" + b}]})
for b in (LEGACY, NEW):
    s3.put_bucket_policy(Bucket=b, Policy=LOG_DELIVERY(b))
for page in s3.get_paginator("list_object_versions").paginate(
        Bucket=LEGACY, Prefix=FLOW_PREFIX):
    objs = [{"Key": o["Key"], "VersionId": o["VersionId"]}
            for o in page.get("Versions", []) + page.get("DeleteMarkers", [])]
    if objs:
        s3.delete_objects(Bucket=LEGACY, Delete={"Objects": objs})

# --- writer 7: an ad-hoc query workgroup parking its results in the retired bucket -------
ath = boto3.client("athena", region_name=EDGE)
ATHENA_WG = "telemetry-adhoc"
ATHENA_PREFIX = "athena-results/"
try:
    ath.delete_work_group(WorkGroup=ATHENA_WG, RecursiveDeleteOption=True)
except Exception:
    pass
ath.create_work_group(
    Name=ATHENA_WG,
    Description="ad-hoc telemetry queries",
    Configuration={"ResultConfiguration": {
        "OutputLocation": "s3://%s/%s" % (LEGACY, ATHENA_PREFIX)}})

# --- writer 6: server access logging on the ingest bucket -------------------------------
ACCESS_PREFIX = "access-logs/"
s3.put_bucket_logging(Bucket=INGEST, BucketLoggingStatus={"LoggingEnabled": {
    "TargetBucket": LEGACY, "TargetPrefix": ACCESS_PREFIX}})

# --- the completion evidence ------------------------------------------------------------
ssm.put_parameter(
    Name="/platform/telemetry/archive-cutover", Overwrite=True, Type="String",
    Value=json.dumps({
        "status": "COMPLETE",
        "completed_on": "2026-08-14",
        "retired_archive": LEGACY,
        "replacement_archive": NEW,
        "regions_in_scope": [REGION, EDGE],
        "sign_off": "platform-data",
    }, indent=2))
for b in (INGEST, NEW, LEGACY):
    s3.put_bucket_tagging(Bucket=b, Tagging={"TagSet": [
        {"Key": "archive-cutover", "Value": "complete"},
        {"Key": "owner", "Value": "platform-data"}]})
s3e.put_bucket_tagging(Bucket=EDGE_INGEST, Tagging={"TagSet": [
    {"Key": "archive-cutover", "Value": "complete"},
    {"Key": "owner", "Value": "platform-data"}]})

for _ in range(40):
    st = fh.describe_delivery_stream(
        DeliveryStreamName="telemetry-raw-stream")["DeliveryStreamDescription"]
    if st["DeliveryStreamStatus"] == "ACTIVE":
        break
    time.sleep(6)


def strip(d):
    return {k: v for k, v in d.items() if k != "ResponseMetadata"}


state = {
    "region": REGION, "edge_region": EDGE, "account": ACCT,
    "legacy_bucket": LEGACY, "new_bucket": NEW, "ingest_bucket": INGEST,
    "compliance_bucket": COMPLIANCE, "edge_bucket": EDGE_INGEST,
    "legacy_keys": LEGACY_KEYS,
    "legacy_versions": [
        {"Key": v["Key"], "VersionId": v["VersionId"], "ETag": v["ETag"]}
        for page in s3.get_paginator("list_object_versions").paginate(Bucket=LEGACY)
        for v in page.get("Versions", [])],
    "firehose_stream": "telemetry-raw-stream",
    "partner_task_name": "partner-drop-nightly",
    "partner_task_arn": partner_task,
    "partner_snapshot": strip(ds.describe_task(TaskArn=partner_task)),
    "partner_source_uri": "s3://%s/partner/" % INGEST,
    "partner_destination_uri": "s3://%s/partner/" % NEW,
    "partner_schedule": SCHEDULE,
    "partner_excludes": EXCLUDES,
    "analytics_task_name": "analytics-export-daily",
    "analytics_snapshot": strip(ds.describe_task(TaskArn=analytics_task)),
    "ingest_replication": strip(s3.get_bucket_replication(Bucket=INGEST)["ReplicationConfiguration"]),
    "edge_replication": strip(s3e.get_bucket_replication(Bucket=EDGE_INGEST)["ReplicationConfiguration"]),
    "roles": {"replication": repl_arn, "firehose": fh_arn, "datasync": ds_arn},
    "edge_vpc": vpc,
    "flow_log_id": flow,
    "flow_log_snapshot": strip(
        ec2e.describe_flow_logs(FlowLogIds=[flow])["FlowLogs"][0]),
    "firehose_snapshot": fh.describe_delivery_stream(
        DeliveryStreamName="telemetry-raw-stream"
    )["DeliveryStreamDescription"]["Destinations"][0],
    "flow_prefix": FLOW_PREFIX,
    "access_log_prefix": ACCESS_PREFIX,
    "athena_workgroup": ATHENA_WG,
    "athena_prefix": ATHENA_PREFIX,
}
out = os.path.join(os.environ.get("TASK_STATE_DIR", "."), "seed_state.json")
with open(out, "w") as f:
    json.dump(state, f, indent=2, default=str)
print("seeded retired archive %s / replacement %s / edge ingest %s" % (LEGACY, NEW, EDGE_INGEST))
PY
