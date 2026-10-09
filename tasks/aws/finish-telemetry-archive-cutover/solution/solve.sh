#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import boto3, json, os, time

REGION = "us-east-1"
REGIONS = ["us-east-1", "us-west-2"]
s3 = boto3.client("s3", region_name=REGION)

buckets = [b["Name"] for b in s3.list_buckets()["Buckets"]]
LEGACY = next(b for b in buckets if b.startswith("telemetry-archive-legacy-"))
NEW = next(b for b in buckets if b.startswith("telemetry-archive-2026-"))
LEGACY_ARN = "arn:aws:s3:::" + LEGACY
print("retired:", LEGACY, "replacement:", NEW)


def bucket_region(name):
    try:
        return s3.get_bucket_location(Bucket=name).get("LocationConstraint") or "us-east-1"
    except Exception:
        return REGION


# --- 1. repoint every Firehose delivery stream that lands in the retired bucket ----------
for reg in REGIONS:
    fh = boto3.client("firehose", region_name=reg)
    try:
        names = fh.list_delivery_streams(Limit=100)["DeliveryStreamNames"]
    except Exception:
        continue
    for name in names:
        d = fh.describe_delivery_stream(DeliveryStreamName=name)["DeliveryStreamDescription"]
        dest = d["Destinations"][0]
        ext = dest.get("ExtendedS3DestinationDescription") or dest.get("S3DestinationDescription")
        if not ext or ext.get("BucketARN") != LEGACY_ARN:
            continue
        fh.update_destination(
            DeliveryStreamName=name,
            CurrentDeliveryStreamVersionId=d["VersionId"],
            DestinationId=dest["DestinationId"],
            ExtendedS3DestinationUpdate={"BucketARN": "arn:aws:s3:::" + NEW})
        print("repointed delivery stream", name)

# --- 2. rebuild every DataSync task whose destination is the retired bucket --------------
for reg in REGIONS:
    ds = boto3.client("datasync", region_name=reg)
    try:
        tasks = ds.list_tasks(MaxResults=100).get("Tasks", [])
    except Exception:
        continue
    for t in tasks:
        d = ds.describe_task(TaskArn=t["TaskArn"])
        try:
            dst = ds.describe_location_s3(LocationArn=d["DestinationLocationArn"])
        except Exception:
            continue
        uri = dst["LocationUri"]
        if not uri.startswith("s3://" + LEGACY + "/"):
            continue
        subdir = "/" + uri.split("/", 3)[3]
        new_loc = ds.create_location_s3(
            Subdirectory=subdir, S3BucketArn="arn:aws:s3:::" + NEW,
            S3Config=dst["S3Config"])["LocationArn"]
        kwargs = {"SourceLocationArn": d["SourceLocationArn"],
                  "DestinationLocationArn": new_loc,
                  "Name": d.get("Name", "")}
        for key in ("Options", "Excludes", "Includes", "Schedule"):
            if d.get(key):
                kwargs[key] = d[key]
        ds.delete_task(TaskArn=t["TaskArn"])
        ds.create_task(**kwargs)
        print("rebuilt DataSync task", d.get("Name"), "in", reg)

# --- 3. the role that performs replication must be able to write where it now delivers ---
iam = boto3.client("iam")
repl_roles = set()
for b in buckets:
    c = boto3.client("s3", region_name=bucket_region(b))
    try:
        cfg = c.get_bucket_replication(Bucket=b)["ReplicationConfiguration"]
    except Exception:
        continue
    if any(r["Destination"]["Bucket"] == LEGACY_ARN for r in cfg["Rules"]):
        repl_roles.add(cfg["Role"].split("/")[-1])
for role in repl_roles:
    for name in iam.list_role_policies(RoleName=role)["PolicyNames"]:
        doc = iam.get_role_policy(RoleName=role, PolicyName=name)["PolicyDocument"]
        changed = False
        for st in doc["Statement"]:
            res = st["Resource"] if isinstance(st["Resource"], list) else [st["Resource"]]
            if any(r.startswith("arn:aws:s3:::" + LEGACY) for r in res):
                want = "arn:aws:s3:::%s/*" % NEW
                if want not in res:
                    res.append(want)
                    st["Resource"] = res
                    changed = True
        if changed:
            iam.put_role_policy(RoleName=role, PolicyName=name,
                                PolicyDocument=json.dumps(doc))
            print("granted", role, "write access to", NEW)
time.sleep(12)

# --- 4. repoint every replication rule that delivers into the retired bucket -------------
for b in buckets:
    reg = bucket_region(b)
    c = boto3.client("s3", region_name=reg)
    try:
        cfg = c.get_bucket_replication(Bucket=b)["ReplicationConfiguration"]
    except Exception:
        continue
    if not any(r["Destination"]["Bucket"] == LEGACY_ARN for r in cfg["Rules"]):
        continue
    for r in cfg["Rules"]:
        if r["Destination"]["Bucket"] == LEGACY_ARN:
            r["Destination"]["Bucket"] = "arn:aws:s3:::" + NEW
    c.put_bucket_replication(
        Bucket=b, ReplicationConfiguration={"Role": cfg["Role"], "Rules": cfg["Rules"]})
    print("repointed archive replication rule on", b, "in", reg)

# --- 5. move every VPC flow log that lands in the retired bucket -------------------------
for reg in REGIONS:
    ec2 = boto3.client("ec2", region_name=reg)
    try:
        logs = ec2.describe_flow_logs()["FlowLogs"]
    except Exception:
        continue
    for f in logs:
        dest = f.get("LogDestination", "")
        if not dest.startswith("arn:aws:s3:::" + LEGACY):
            continue
        ec2.create_flow_logs(
            ResourceIds=[f["ResourceId"]], ResourceType=f.get("ResourceType", "VPC"),
            TrafficType=f.get("TrafficType", "ALL"), LogDestinationType="s3",
            LogDestination=dest.replace("arn:aws:s3:::" + LEGACY,
                                        "arn:aws:s3:::" + NEW))
        ec2.delete_flow_logs(FlowLogIds=[f["FlowLogId"]])
        print("moved flow log", f["FlowLogId"], "in", reg)

# --- 6. move server access logging that lands in the retired bucket ----------------------
for b in buckets:
    c = boto3.client("s3", region_name=bucket_region(b))
    try:
        log = c.get_bucket_logging(Bucket=b).get("LoggingEnabled")
    except Exception:
        continue
    if not log or log.get("TargetBucket") != LEGACY:
        continue
    log["TargetBucket"] = NEW
    c.put_bucket_logging(Bucket=b, BucketLoggingStatus={"LoggingEnabled": log})
    print("moved access logging on", b)

# --- 7. move any query workgroup parking its results in the retired bucket ---------------
for reg in REGIONS:
    ath = boto3.client("athena", region_name=reg)
    try:
        groups = ath.list_work_groups()["WorkGroups"]
    except Exception:
        continue
    for g in groups:
        wg = ath.get_work_group(WorkGroup=g["Name"])["WorkGroup"]
        out = (wg.get("Configuration", {}).get("ResultConfiguration", {})
               .get("OutputLocation", ""))
        if not out.startswith("s3://" + LEGACY + "/"):
            continue
        ath.update_work_group(
            WorkGroup=g["Name"],
            ConfigurationUpdates={"ResultConfigurationUpdates": {
                "OutputLocation": out.replace("s3://" + LEGACY + "/",
                                              "s3://" + NEW + "/")}})
        print("moved workgroup results for", g["Name"], "in", reg)

time.sleep(5)
print("cutover finished")
PY
