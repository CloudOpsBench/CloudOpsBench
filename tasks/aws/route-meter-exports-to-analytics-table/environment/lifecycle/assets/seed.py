"""Seeds the metering export pipeline.

Two live delivery streams disagree about where interval readings belong. The one whose NAME
matches the analytics table lands in the compliance archive bucket; the one that actually
writes into the curated location the catalog table reads is named after something else. All
three exporters point at the name-matching stream, and the Lambda exporter's live alias is
pinned to a published version, so updating the function's configuration does not change what
the alias serves.

The stream that lands at the curated location is itself unable to write there: its delivery
role grants the archive bucket, not the one it points at. Nothing about the stream says so -
describe-delivery-stream reads perfectly - so simply repointing the exporters at it moves
nothing. The Glue job's run-time argument is pinned in NonOverridableArguments, so editing
DefaultArguments alone is inert as well.
"""
import io
import json
import os
import time
import uuid
import zipfile

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
SECONDARY = "us-west-2" if REGION != "us-west-2" else "us-east-2"
SFX = uuid.uuid4().hex[:8]
ACCT = boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]

s3 = boto3.client("s3", region_name=REGION)
iam = boto3.client("iam", region_name=REGION)
fh = boto3.client("firehose", region_name=REGION)
lam = boto3.client("lambda", region_name=REGION)
glue = boto3.client("glue", region_name=REGION)
batch = boto3.client("batch", region_name=REGION)

CURATED = "meter-curated-%s-%s" % (ACCT, SFX)
ARCHIVE = "meter-archive-%s-%s" % (ACCT, SFX)
PREFIX = "interval/readings/"

# The stream whose name matches the analytics table is the one landing in the archive.
LURE_STREAM = "meter-interval-readings-feed-%s" % SFX
REAL_STREAM = "grid-telemetry-delivery-%s" % SFX

DB = "meter_analytics_%s" % SFX
TABLE = "interval_readings"

FN = "meter-export-writer-%s" % SFX
JOBDEF = "meter-export-batch-%s" % SFX
GLUEJOB = "meter-export-nightly-%s" % SFX
CBPROJECT = "meter-export-secondary-%s" % SFX

FH_ARCHIVE_ROLE = "meter-fh-archive-%s" % SFX
FH_CURATED_ROLE = "meter-fh-curated-%s" % SFX
FN_ROLE = "meter-export-writer-role-%s" % SFX
GLUE_ROLE = "meter-glue-export-%s" % SFX
CB_ROLE = "meter-codebuild-export-%s" % SFX


def make_role(name, service, policy):
    trust = {"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow", "Principal": {"Service": service}, "Action": "sts:AssumeRole"}]}
    try:
        arn = iam.create_role(RoleName=name,
                              AssumeRolePolicyDocument=json.dumps(trust))["Role"]["Arn"]
    except iam.exceptions.EntityAlreadyExistsException:
        arn = iam.get_role(RoleName=name)["Role"]["Arn"]
    iam.put_role_policy(RoleName=name, PolicyName="inline",
                        PolicyDocument=json.dumps(policy))
    return arn


for b in (CURATED, ARCHIVE):
    s3.create_bucket(Bucket=b)

def delivery_policy(buckets):
    return {"Version": "2012-10-17", "Statement": [
        {"Effect": "Allow",
         "Action": ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject",
                    "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject"],
         "Resource": sum([["arn:aws:s3:::%s" % b, "arn:aws:s3:::%s/*" % b]
                          for b in buckets], [])},
        {"Effect": "Allow", "Action": ["logs:PutLogEvents"],
         "Resource": "arn:aws:logs:%s:%s:log-group:/aws/kinesisfirehose/*" % (REGION, ACCT)}]}


# Both delivery roles are created able to write either bucket, so stream creation validates,
# and are narrowed to the ARCHIVE bucket only once the streams exist. That leaves the curated
# stream reading perfectly while its delivery role cannot write where it points.
archive_role = make_role(FH_ARCHIVE_ROLE, "firehose.amazonaws.com",
                         delivery_policy([CURATED, ARCHIVE]))
curated_role = make_role(FH_CURATED_ROLE, "firehose.amazonaws.com",
                         delivery_policy([CURATED, ARCHIVE]))

# PutRecord on every stream in the account, so an exporter pointed at the wrong stream still
# succeeds: nothing in this task is discovered by watching a call fail.
fn_role = make_role(FN_ROLE, "lambda.amazonaws.com", {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Action": ["firehose:PutRecord", "firehose:PutRecordBatch"],
     "Resource": "arn:aws:firehose:%s:%s:deliverystream/*" % (REGION, ACCT)},
    {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream",
                                   "logs:PutLogEvents"], "Resource": "*"}]})

glue_role = make_role(GLUE_ROLE, "glue.amazonaws.com", {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Action": ["firehose:PutRecord", "firehose:PutRecordBatch"],
     "Resource": "arn:aws:firehose:%s:%s:deliverystream/*" % (REGION, ACCT)},
    {"Effect": "Allow", "Action": ["s3:GetObject", "s3:ListBucket"], "Resource": "*"}]})

time.sleep(12)  # role propagation before Firehose validates the delivery role


def make_stream(name, bucket, role):
    fh.create_delivery_stream(
        DeliveryStreamName=name, DeliveryStreamType="DirectPut",
        ExtendedS3DestinationConfiguration={
            "RoleARN": role, "BucketARN": "arn:aws:s3:::%s" % bucket, "Prefix": PREFIX,
            "ErrorOutputPrefix": "errors/",
            "BufferingHints": {"SizeInMBs": 1, "IntervalInSeconds": 60},
            "CompressionFormat": "UNCOMPRESSED",
            "CloudWatchLoggingOptions": {"Enabled": False}})


make_stream(LURE_STREAM, ARCHIVE, archive_role)
make_stream(REAL_STREAM, CURATED, curated_role)

# The archive already holds historical exports; the curated location is empty. That is the
# symptom the prompt describes, and it says nothing about which stream writes where.
for day in ("2026/08/26", "2026/08/27", "2026/08/28"):
    body = json.dumps({"meter_id": "M-1001", "read_ts": day, "kwh": 4.5}) + "\n"
    s3.put_object(Bucket=ARCHIVE, Key="%s%s/meter-export-1.json" % (PREFIX, day),
                  Body=body.encode())

glue.create_database(DatabaseInput={"Name": DB,
                                    "Description": "Metering analytics datasets"})
glue.create_table(DatabaseName=DB, TableInput={
    "Name": TABLE, "TableType": "EXTERNAL_TABLE",
    "Parameters": {"classification": "json"},
    "StorageDescriptor": {
        "Columns": [{"Name": "meter_id", "Type": "string"},
                    {"Name": "read_ts", "Type": "string"},
                    {"Name": "kwh", "Type": "double"}],
        "Location": "s3://%s/%s" % (CURATED, PREFIX),
        "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
        "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
        "SerdeInfo": {"SerializationLibrary": "org.openx.data.jsonserde.JsonSerDe"}}})

FN_CODE = "\n".join([
    "import json, os, boto3",
    "",
    "def handler(event, context):",
    "    stream = os.environ['EXPORT_DELIVERY_STREAM']",
    "    reading = {'meter_id': str(event.get('marker', 'probe')),",
    "               'read_ts': '2026-08-29T00:00:00Z', 'kwh': 1.0}",
    "    body = json.dumps(reading) + chr(10)",
    "    r = boto3.client('firehose').put_record(DeliveryStreamName=stream,",
    "                                            Record={'Data': body.encode()})",
    "    return {'stream': stream, 'record_id': r['RecordId']}",
    "",
])

buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    z.writestr("index.py", FN_CODE)

for attempt in range(6):
    try:
        lam.create_function(
            FunctionName=FN, Runtime="python3.12", Role=fn_role, Handler="index.handler",
            Code={"ZipFile": buf.getvalue()}, Timeout=30,
            Description="Streams interval readings into the export delivery stream",
            Environment={"Variables": {"EXPORT_DELIVERY_STREAM": LURE_STREAM}})
        break
    except ClientError as e:
        if e.response["Error"]["Code"] != "InvalidParameterValueException" or attempt == 5:
            raise
        time.sleep(10)

lam.get_waiter("function_active_v2").wait(FunctionName=FN)
version = lam.publish_version(FunctionName=FN)["Version"]
lam.create_alias(FunctionName=FN, Name="live", FunctionVersion=version,
                 Description="Version the export scheduler invokes")

batch.register_job_definition(
    jobDefinitionName=JOBDEF, type="container",
    containerProperties={
        "image": "public.ecr.aws/amazonlinux/amazonlinux:2", "vcpus": 1, "memory": 512,
        "command": ["/bin/sh", "-c", "python3 /opt/export/run.py"],
        "environment": [{"name": "EXPORT_DELIVERY_STREAM", "value": LURE_STREAM},
                        {"name": "EXPORT_WINDOW_MINUTES", "value": "15"}]})

glue.create_job(
    Name=GLUEJOB, Role=glue_role, GlueVersion="4.0", MaxRetries=0,
    Description="Nightly interval reading export",
    Command={"Name": "glueetl", "PythonVersion": "3",
             "ScriptLocation": "s3://%s/scripts/meter_export.py" % ARCHIVE},
    DefaultArguments={"--EXPORT_DELIVERY_STREAM": LURE_STREAM,
                      "--job-language": "python",
                      "--enable-metrics": "true"},
    NonOverridableArguments={"--EXPORT_DELIVERY_STREAM": LURE_STREAM},
    NumberOfWorkers=2, WorkerType="G.1X")

cb_role = make_role(CB_ROLE, "codebuild.amazonaws.com", {"Version": "2012-10-17",
    "Statement": [
        {"Effect": "Allow", "Action": ["firehose:PutRecord", "firehose:PutRecordBatch"],
         "Resource": "arn:aws:firehose:%s:%s:deliverystream/*" % (REGION, ACCT)},
        {"Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream",
                                       "logs:PutLogEvents"], "Resource": "*"}]})

BUILDSPEC = chr(10).join([
    "version: 0.2",
    "phases:",
    "  build:",
    "    commands:",
    "      - python3 export_interval_readings.py --stream \"$EXPORT_DELIVERY_STREAM\"",
    "",
])

codebuild = boto3.client("codebuild", region_name=SECONDARY)
for attempt in range(8):
    try:
        codebuild.create_project(
            name=CBPROJECT, serviceRole=cb_role,
            description="Secondary region interval reading export",
            source={"type": "NO_SOURCE", "buildspec": BUILDSPEC},
            artifacts={"type": "NO_ARTIFACTS"},
            environment={"type": "LINUX_CONTAINER",
                         "image": "aws/codebuild/standard:7.0",
                         "computeType": "BUILD_GENERAL1_SMALL",
                         "environmentVariables": [
                             {"name": "EXPORT_DELIVERY_STREAM", "value": LURE_STREAM,
                              "type": "PLAINTEXT"},
                             {"name": "EXPORT_REGION", "value": REGION,
                              "type": "PLAINTEXT"}]})
        break
    except ClientError as e:  # the service role is not assumable yet
        if e.response["Error"]["Code"] != "InvalidInputException" or attempt == 7:
            raise
        time.sleep(10)

for name in (LURE_STREAM, REAL_STREAM):
    for _ in range(60):
        d = fh.describe_delivery_stream(DeliveryStreamName=name)["DeliveryStreamDescription"]
        if d["DeliveryStreamStatus"] == "ACTIVE":
            break
        time.sleep(5)


# Both delivery roles now grant the ARCHIVE bucket only. For the archive stream that is
# consistent; for the curated stream the destination and the grant name different buckets.
for role_name in (FH_ARCHIVE_ROLE, FH_CURATED_ROLE):
    iam.put_role_policy(RoleName=role_name, PolicyName="inline",
                        PolicyDocument=json.dumps(delivery_policy([ARCHIVE])))


def snapshot(name):
    d = fh.describe_delivery_stream(DeliveryStreamName=name)["DeliveryStreamDescription"]
    return json.loads(json.dumps(d["Destinations"], default=str))


state = {
    "region": REGION, "sfx": SFX, "curated_bucket": CURATED, "archive_bucket": ARCHIVE,
    "prefix": PREFIX, "lure_stream": LURE_STREAM, "real_stream": REAL_STREAM,
    "database": DB, "table": TABLE, "function": FN, "alias": "live",
    "job_definition": JOBDEF, "glue_job": GLUEJOB,
    "roles": [FH_ARCHIVE_ROLE, FH_CURATED_ROLE, FN_ROLE, GLUE_ROLE, CB_ROLE],
    "secondary_region": SECONDARY, "codebuild_project": CBPROJECT,
    "stream_snapshots": {LURE_STREAM: snapshot(LURE_STREAM),
                         REAL_STREAM: snapshot(REAL_STREAM)},
    "table_snapshot": json.loads(json.dumps(
        glue.get_table(DatabaseName=DB, Name=TABLE)["Table"], default=str)),
}

out = os.path.join(os.environ.get("TASK_STATE_DIR", os.getcwd()), "seed_state.json")
with open(out, "w") as f:
    json.dump(state, f, indent=2)
print("seeded %s" % SFX)
