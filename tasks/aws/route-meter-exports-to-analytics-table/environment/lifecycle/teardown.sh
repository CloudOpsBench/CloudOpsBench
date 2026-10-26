#!/usr/bin/env bash
# Best-effort cleanup of the resources recorded in seed_state.json; never fails.
set -uo pipefail
export MSYS_NO_PATHCONV=1

python3 <<'PY' || true
import json
import os

import boto3

try:
    seed = json.load(open(os.path.join(os.environ.get("TASK_STATE_DIR", "."),
                                       "seed_state.json")))
except Exception:
    try:
        seed = json.load(open("seed_state.json"))
    except Exception:
        raise SystemExit(0)

R = seed.get("region", "us-east-1")
s3 = boto3.client("s3", region_name=R)
iam = boto3.client("iam", region_name=R)
fh = boto3.client("firehose", region_name=R)
lam = boto3.client("lambda", region_name=R)
glue = boto3.client("glue", region_name=R)
batch = boto3.client("batch", region_name=R)


def quiet(fn, *a, **k):
    try:
        return fn(*a, **k)
    except Exception:
        return None


quiet(lam.delete_function, FunctionName=seed["function"])
for name in (seed["lure_stream"], seed["real_stream"]):
    quiet(fh.delete_delivery_stream, DeliveryStreamName=name, AllowForceDelete=True)
# any stream created at the curated location
resp = quiet(fh.list_delivery_streams, Limit=100) or {}
for name in resp.get("DeliveryStreamNames", []):
    if name.startswith("meter-") or name.startswith("grid-"):
        quiet(fh.delete_delivery_stream, DeliveryStreamName=name, AllowForceDelete=True)
if seed.get("codebuild_project"):
    cb = boto3.client("codebuild", region_name=seed.get("secondary_region", "us-west-2"))
    quiet(cb.delete_project, name=seed["codebuild_project"])
quiet(glue.delete_job, JobName=seed["glue_job"])
quiet(glue.delete_table, DatabaseName=seed["database"], Name=seed["table"])
quiet(glue.delete_database, Name=seed["database"])

jds = quiet(batch.describe_job_definitions,
            jobDefinitionName=seed["job_definition"], status="ACTIVE") or {}
for jd in jds.get("jobDefinitions", []):
    quiet(batch.deregister_job_definition, jobDefinition=jd["jobDefinitionArn"])

for bucket in (seed["curated_bucket"], seed["archive_bucket"]):
    try:
        for page in s3.get_paginator("list_object_versions").paginate(Bucket=bucket):
            for obj in page.get("Versions", []) + page.get("DeleteMarkers", []):
                quiet(s3.delete_object, Bucket=bucket, Key=obj["Key"],
                      VersionId=obj["VersionId"])
    except Exception:
        pass
    quiet(s3.delete_bucket, Bucket=bucket)

for role in seed.get("roles", []):
    listed = quiet(iam.list_role_policies, RoleName=role) or {}
    for policy in listed.get("PolicyNames", []):
        quiet(iam.delete_role_policy, RoleName=role, PolicyName=policy)
    attached = quiet(iam.list_attached_role_policies, RoleName=role) or {}
    for policy in attached.get("AttachedPolicies", []):
        quiet(iam.detach_role_policy, RoleName=role, PolicyArn=policy["PolicyArn"])
    quiet(iam.delete_role, RoleName=role)
PY
