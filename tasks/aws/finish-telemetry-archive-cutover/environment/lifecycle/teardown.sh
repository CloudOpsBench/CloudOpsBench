#!/usr/bin/env bash
# Courtesy cleanup. A lane nuke resets state anyway, so never fail the run here.
set -uo pipefail
python3 - <<'PY' 2>/dev/null || true
import boto3, json, os

path = os.path.join(os.environ.get("TASK_STATE_DIR", "."), "seed_state.json")
seed = json.load(open(path))
REGION, EDGE = seed["region"], seed["edge_region"]

for reg in (REGION, EDGE):
    d = boto3.client("datasync", region_name=reg)
    try:
        for t in d.list_tasks(MaxResults=100).get("Tasks", []):
            try:
                d.delete_task(TaskArn=t["TaskArn"])
            except Exception:
                pass
        for l in d.list_locations(MaxResults=100).get("Locations", []):
            try:
                d.delete_location(LocationArn=l["LocationArn"])
            except Exception:
                pass
    except Exception:
        pass
    f = boto3.client("firehose", region_name=reg)
    try:
        for n in f.list_delivery_streams(Limit=100)["DeliveryStreamNames"]:
            try:
                f.delete_delivery_stream(DeliveryStreamName=n)
            except Exception:
                pass
    except Exception:
        pass

try:
    boto3.client("athena", region_name=EDGE).delete_work_group(
        WorkGroup=seed["athena_workgroup"], RecursiveDeleteOption=True)
except Exception:
    pass

e = boto3.client("ec2", region_name=EDGE)
try:
    ids = [f["FlowLogId"] for f in e.describe_flow_logs()["FlowLogs"]]
    if ids:
        e.delete_flow_logs(FlowLogIds=ids)
except Exception:
    pass
try:
    e.delete_vpc(VpcId=seed["edge_vpc"])
except Exception:
    pass

for b, reg in ((seed["legacy_bucket"], REGION), (seed["new_bucket"], REGION),
               (seed["ingest_bucket"], REGION), (seed["compliance_bucket"], REGION),
               (seed["edge_bucket"], EDGE)):
    c = boto3.client("s3", region_name=reg)
    try:
        c.delete_bucket_replication(Bucket=b)
    except Exception:
        pass
    try:
        for page in c.get_paginator("list_object_versions").paginate(Bucket=b):
            objs = [{"Key": o["Key"], "VersionId": o["VersionId"]}
                    for o in page.get("Versions", []) + page.get("DeleteMarkers", [])]
            if objs:
                c.delete_objects(Bucket=b, Delete={"Objects": objs})
        c.delete_bucket(Bucket=b)
    except Exception:
        pass

iam = boto3.client("iam")
for r in ("telemetry-archive-replication-role", "telemetry-archive-firehose-role",
          "telemetry-archive-datasync-role"):
    try:
        for p in iam.list_role_policies(RoleName=r)["PolicyNames"]:
            iam.delete_role_policy(RoleName=r, PolicyName=p)
        iam.delete_role(RoleName=r)
    except Exception:
        pass

try:
    boto3.client("ssm", region_name=REGION).delete_parameter(
        Name="/platform/telemetry/archive-cutover")
except Exception:
    pass
PY
exit 0
