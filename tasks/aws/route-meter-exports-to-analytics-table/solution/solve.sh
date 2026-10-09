#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

python3 <<'PY'
import time

import json

import boto3

REGION = boto3.session.Session().region_name or "us-east-1"
fh = boto3.client("firehose", region_name=REGION)
iam = boto3.client("iam", region_name=REGION)
glue = boto3.client("glue", region_name=REGION)
lam = boto3.client("lambda", region_name=REGION)
batch = boto3.client("batch", region_name=REGION)

SETTING = "EXPORT_DELIVERY_STREAM"

# 1. Where does the analytics table actually read from?
target = None
db_name = None
for page in glue.get_paginator("get_databases").paginate():
    for db in page["DatabaseList"]:
        try:
            tbl = glue.get_table(DatabaseName=db["Name"], Name="interval_readings")["Table"]
        except glue.exceptions.EntityNotFoundException:
            continue
        db_name = db["Name"]
        target = tbl["StorageDescriptor"]["Location"].rstrip("/")
if target is None:
    raise SystemExit("no interval_readings table found")
print("table %s.interval_readings reads %s" % (db_name, target))

# 2. Which delivery stream lands there? Names say nothing; the destination does.
streams = []
last = None
while True:
    kwargs = {"Limit": 100}
    if last:
        kwargs["ExclusiveStartDeliveryStreamName"] = last
    resp = fh.list_delivery_streams(**kwargs)
    streams.extend(resp["DeliveryStreamNames"])
    if not resp.get("HasMoreDeliveryStreams"):
        break
    last = streams[-1]

wanted = None
wanted_role = None
for name in streams:
    d = fh.describe_delivery_stream(DeliveryStreamName=name)["DeliveryStreamDescription"]
    for dst in d.get("Destinations", []):
        cfg = dst.get("ExtendedS3DestinationDescription") or dst.get("S3DestinationDescription")
        if not cfg or not cfg.get("BucketARN"):
            continue
        uri = ("s3://%s/%s" % (cfg["BucketARN"].split(":::")[-1],
                               cfg.get("Prefix", ""))).rstrip("/")
        if uri == target:
            wanted = name
            wanted_role = cfg.get("RoleARN")
if wanted is None:
    raise SystemExit("no delivery stream lands at %s" % target)
print("delivery stream %s lands at %s" % (wanted, target))

bucket, _, key_prefix = target.split("://", 1)[1].partition("/")
objects = "arn:aws:s3:::%s/%s/*" % (bucket, key_prefix.rstrip("/"))
role_name = wanted_role.split("/")[-1]
decision = iam.simulate_principal_policy(
    PolicySourceArn=wanted_role, ActionNames=["s3:PutObject"],
    ResourceArns=[objects])["EvaluationResults"][0]["EvalDecision"]
print("role %s currently evaluates s3:PutObject on %s as %s" % (role_name, objects, decision))
if decision != "allowed":
    iam.put_role_policy(RoleName=role_name, PolicyName="curated-delivery",
                        PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [
                            {"Effect": "Allow",
                             "Action": ["s3:AbortMultipartUpload", "s3:GetBucketLocation",
                                        "s3:GetObject", "s3:ListBucket",
                                        "s3:ListBucketMultipartUploads", "s3:PutObject"],
                             "Resource": ["arn:aws:s3:::%s" % bucket, objects]}]}))
    for _ in range(30):
        time.sleep(5)
        if iam.simulate_principal_policy(
                PolicySourceArn=wanted_role, ActionNames=["s3:PutObject"],
                ResourceArns=[objects])["EvaluationResults"][0]["EvalDecision"] == "allowed":
            break
    print("granted %s write access to %s" % (role_name, objects))

# 3. The Lambda exporter: fix $LATEST, publish it, then move the alias onto the new version.
for page in lam.get_paginator("list_functions").paginate():
    for f in page["Functions"]:
        if not f["FunctionName"].startswith("meter-export-writer-"):
            continue
        fn = f["FunctionName"]
        env = lam.get_function(FunctionName=fn)["Configuration"].get("Environment") or {}
        variables = dict(env.get("Variables", {}))
        variables[SETTING] = wanted
        lam.update_function_configuration(FunctionName=fn,
                                          Environment={"Variables": variables})
        lam.get_waiter("function_updated_v2").wait(FunctionName=fn)
        version = lam.publish_version(FunctionName=fn)["Version"]
        for alias in lam.list_aliases(FunctionName=fn)["Aliases"]:
            lam.update_alias(FunctionName=fn, Name=alias["Name"], FunctionVersion=version)
            print("alias %s:%s -> version %s" % (fn, alias["Name"], version))

# 4. The Batch job definition is immutable: register a new revision.
active = []
for page in batch.get_paginator("describe_job_definitions").paginate(status="ACTIVE"):
    active.extend(page["jobDefinitions"])
by_name = {}
for jd in active:
    if jd["jobDefinitionName"].startswith("meter-export-batch-"):
        cur = by_name.get(jd["jobDefinitionName"])
        if cur is None or jd["revision"] > cur["revision"]:
            by_name[jd["jobDefinitionName"]] = jd
for name, jd in by_name.items():
    props = dict(jd["containerProperties"])
    props["environment"] = [{"name": e["name"],
                             "value": wanted if e["name"] == SETTING else e["value"]}
                            for e in props.get("environment", [])]
    kwargs = {"jobDefinitionName": name, "type": jd["type"], "containerProperties": props}
    if jd.get("parameters"):
        kwargs["parameters"] = jd["parameters"]
    if jd.get("platformCapabilities"):
        kwargs["platformCapabilities"] = jd["platformCapabilities"]
    new = batch.register_job_definition(**kwargs)
    print("registered %s revision %s" % (name, new["revision"]))

regions = [r["RegionName"] for r in
           boto3.client("ec2", region_name=REGION).describe_regions()["Regions"]]
for rgn in regions:
    cb = boto3.client("codebuild", region_name=rgn)
    try:
        names = [n for page in cb.get_paginator("list_projects").paginate()
                 for n in page["projects"] if n.startswith("meter-export-secondary-")]
    except Exception:
        continue
    for name in names:
        proj = cb.batch_get_projects(names=[name])["projects"][0]
        env = proj["environment"]
        env["environmentVariables"] = [
            {"name": v["name"], "value": wanted if v["name"] == SETTING else v["value"],
             "type": v.get("type", "PLAINTEXT")}
            for v in env.get("environmentVariables", [])]
        cb.update_project(name=name, environment=env)
        print("codebuild %s in %s -> %s" % (name, rgn, wanted))

# 6. The Glue job.
for page in glue.get_paginator("get_jobs").paginate():
    for job in page["Jobs"]:
        if not job["Name"].startswith("meter-export-nightly-"):
            continue
        update = {k: job[k] for k in
                  ("Role", "Command", "DefaultArguments", "NonOverridableArguments",
                   "Connections", "MaxRetries", "Timeout", "GlueVersion",
                   "NumberOfWorkers", "WorkerType", "Description", "ExecutionProperty")
                  if k in job}
        args = dict(update.get("DefaultArguments") or {})
        args["--" + SETTING] = wanted
        update["DefaultArguments"] = args
        # The non-overridable copy is what the run actually uses, so it has to move too.
        if update.get("NonOverridableArguments"):
            fixed = dict(update["NonOverridableArguments"])
            if "--" + SETTING in fixed:
                fixed["--" + SETTING] = wanted
            update["NonOverridableArguments"] = fixed
        glue.update_job(JobName=job["Name"], JobUpdate=update)
        print("glue job %s -> %s" % (job["Name"], wanted))

time.sleep(5)
PY
