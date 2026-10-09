"""Grader. Live probes are written first and judged last, so the outcome test always runs and
the propagation wait overlaps every configuration check instead of being added to it.
Exit 0 = PASS."""
import json
import time
import uuid

import boto3
import checkkit as ck

seed = ck.seed()
REGION = seed["region"]
EDGE = seed["edge_region"]
LEGACY = seed["legacy_bucket"]
NEW = seed["new_bucket"]
INGEST = seed["ingest_bucket"]
COMPLIANCE = seed["compliance_bucket"]
EDGE_INGEST = seed["edge_bucket"]
LEGACY_ARN = "arn:aws:s3:::" + LEGACY
NEW_ARN = "arn:aws:s3:::" + NEW

s3 = boto3.client("s3", region_name=REGION)
s3e = boto3.client("s3", region_name=EDGE)

VOLATILE = {"ResponseMetadata", "CreationTime", "Status", "CurrentTaskExecutionArn",
            "ErrorCode", "ErrorDetail"}
_deferred = []


def need(cond, msg):
    """Record a configuration failure instead of exiting, so the live outcome is still judged
    on its own evidence and reported first."""
    if not cond:
        _deferred.append(msg)
    return bool(cond)


def strip(d):
    return {k: v for k, v in d.items() if k not in VOLATILE}


def has_key(client, bucket, key):
    try:
        client.head_object(Bucket=bucket, Key=key)
        return True
    except Exception:
        return False


def bucket_region(name):
    try:
        return s3.get_bucket_location(Bucket=name).get("LocationConstraint") or "us-east-1"
    except Exception:
        return REGION


def canon(x):
    return json.dumps(x, sort_keys=True, default=str)


# ------------------------------------------------- probes go in before anything else -----
tag = uuid.uuid4().hex[:10]
probe_in = "telemetry/grader-probe-%s.json" % tag
probe_edge = "telemetry/grader-probe-edge-%s.json" % tag
body = json.dumps({"probe": tag}).encode()
s3.put_object(Bucket=INGEST, Key=probe_in, Body=body)
s3e.put_object(Bucket=EDGE_INGEST, Key=probe_edge, Body=body)
sent_at = time.time()


def legacy_received():
    for k, where in ((probe_in, INGEST), (probe_edge, EDGE_INGEST)):
        if has_key(s3, LEGACY, k):
            return (
                "a probe object written to %s at %s replicated into the retired archive %s "
                "as %s, %d seconds later. Nothing may write a new object into that bucket."
                % (where, time.strftime("%H:%M:%SZ", time.gmtime(sent_at)), LEGACY, k,
                   int(time.time() - sent_at)))
    return None


# ------------------------------------------------- audit hold ----------------------------
def version_intact(entry):
    """The exact seeded version must still be there, byte for byte. Deleting every version of
    a key and putting the content back is still a modification of audit-held history."""
    try:
        got = s3.head_object(Bucket=LEGACY, Key=entry["Key"], VersionId=entry["VersionId"])
    except Exception:
        return False
    return got.get("ETag") == entry["ETag"]


gone = [e for e in seed["legacy_versions"] if not version_intact(e)]
need(not gone,
     "the retired archive %s is under audit hold and its objects had to be left untouched, "
     "but %d of %d seeded object versions no longer read back with their original content: %s"
     % (LEGACY, len(gone), len(seed["legacy_versions"]),
        json.dumps([{"Key": e["Key"], "VersionId": e["VersionId"]} for e in gone[:5]])))

# ------------------------------------------------- restraint -----------------------------
tasks = {}
for reg in (REGION, EDGE):
    d = boto3.client("datasync", region_name=reg)
    for t in d.list_tasks(MaxResults=100).get("Tasks", []):
        tasks.setdefault(t.get("Name"), []).append((reg, t["TaskArn"]))

if need(seed["analytics_task_name"] in tasks,
        "DataSync task %s is not part of this cutover and had to be left alone, but no task "
        "with that name exists any more" % seed["analytics_task_name"]):
    areg, aarn = tasks[seed["analytics_task_name"]][0]
    current = strip(boto3.client("datasync", region_name=areg).describe_task(TaskArn=aarn))
    snapshot = strip(seed["analytics_snapshot"])
    diff = sorted(k for k in set(current) | set(snapshot)
                  if canon(current.get(k)) != canon(snapshot.get(k)))
    need(not diff,
         "DataSync task %s had to be left exactly as it was, but these fields changed: %s. "
         "seeded=%s current=%s"
         % (seed["analytics_task_name"], ", ".join(diff),
            json.dumps({k: snapshot.get(k) for k in diff}, default=str),
            json.dumps({k: current.get(k) for k in diff}, default=str)))

for bucket, client, seeded in ((INGEST, s3, seed["ingest_replication"]),
                               (EDGE_INGEST, s3e, seed["edge_replication"])):
    try:
        cfg = client.get_bucket_replication(Bucket=bucket)["ReplicationConfiguration"]
    except Exception as exc:
        need(False,
             "replication into the compliance bucket %s had to keep working, but %s has no "
             "replication configuration at all any more (%s)"
             % (COMPLIANCE, bucket, type(exc).__name__))
        continue
    for rule in [r for r in seeded["Rules"]
                 if r["Destination"]["Bucket"].endswith(COMPLIANCE)]:
        match = [r for r in cfg["Rules"] if r.get("ID") == rule.get("ID")]
        if not need(match,
                    "replication rule %s on %s delivers to the compliance bucket %s and had "
                    "to be left unchanged, but it is gone. Remaining rule ids: %s"
                    % (rule.get("ID"), bucket, COMPLIANCE,
                       [r.get("ID") for r in cfg["Rules"]])):
            continue
        need(canon(match[0]) == canon(rule),
             "replication rule %s on %s delivers to the compliance bucket and had to be left "
             "unchanged. seeded=%s current=%s"
             % (rule.get("ID"), bucket, canon(rule), canon(match[0])))
    # the source that fed the retired archive now feeds the replacement, same filter
    for old_rule in [r for r in seeded["Rules"] if r["Destination"]["Bucket"] == LEGACY_ARN]:
        want = {k: v for k, v in old_rule.items() if k not in ("ID", "Priority")}
        want["Destination"] = dict(want["Destination"], Bucket=NEW_ARN)
        need([r for r in cfg["Rules"]
              if canon({k: v for k, v in r.items() if k not in ("ID", "Priority")})
              == canon(want)],
             "%s replicated into the retired archive and has to replicate into the "
             "replacement archive with every other setting unchanged. Expected a rule "
             "matching %s; its current rules are %s"
             % (bucket, canon(want),
                json.dumps([{k: v for k, v in r.items() if k not in ("ID", "Priority")}
                            for r in cfg["Rules"]], default=str)))

# ------------------------------------------------- continuity ----------------------------
fh = boto3.client("firehose", region_name=REGION)
try:
    stream = fh.describe_delivery_stream(
        DeliveryStreamName=seed["firehose_stream"])["DeliveryStreamDescription"]
except Exception as exc:
    stream = None
    need(False, "delivery stream %s had to stay ACTIVE and keep archiving raw telemetry, but "
                "it no longer exists (%s)" % (seed["firehose_stream"], type(exc).__name__))
if stream:
    need(stream["DeliveryStreamStatus"] == "ACTIVE",
         "delivery stream %s had to stay ACTIVE, current status is %s"
         % (seed["firehose_stream"], stream["DeliveryStreamStatus"]))
    dest = stream["Destinations"][0]
    ext = (dest.get("ExtendedS3DestinationDescription")
           or dest.get("S3DestinationDescription") or {})
    need(ext.get("BucketARN") == NEW_ARN,
         "delivery stream %s had to archive into the replacement bucket %s, its S3 "
         "destination is %s" % (seed["firehose_stream"], NEW, ext.get("BucketARN")))
    seeded_dest = seed["firehose_snapshot"]
    want_ext = (seeded_dest.get("ExtendedS3DestinationDescription")
                or seeded_dest.get("S3DestinationDescription") or {})
    skip = ("BucketARN", "RoleARN")
    drift = sorted(k for k in set(want_ext) | set(ext)
                   if k not in skip and canon(want_ext.get(k)) != canon(ext.get(k)))
    need(not drift,
         "delivery stream %s had to keep every setting except where it delivers, but these "
         "changed: %s. seeded=%s current=%s"
         % (seed["firehose_stream"], ", ".join(drift),
            json.dumps({k: want_ext.get(k) for k in drift}, default=str),
            json.dumps({k: ext.get(k) for k in drift}, default=str)))

if need(seed["partner_task_name"] in tasks,
        "a DataSync task named %s had to still exist after the cutover; no task with that "
        "name was found in %s or %s" % (seed["partner_task_name"], REGION, EDGE)):
    preg, parn = tasks[seed["partner_task_name"]][0]
    pds = boto3.client("datasync", region_name=preg)
    pt = pds.describe_task(TaskArn=parn)
    psrc = pds.describe_location_s3(LocationArn=pt["SourceLocationArn"])["LocationUri"]
    need(psrc == seed["partner_source_uri"],
         "DataSync task %s had to keep reading from the same source location; seeded %s, "
         "current %s" % (seed["partner_task_name"], seed["partner_source_uri"], psrc))
    pdst = pds.describe_location_s3(LocationArn=pt["DestinationLocationArn"])["LocationUri"]
    need(pdst == seed["partner_destination_uri"],
         "DataSync task %s had to write the same data into the replacement archive under the "
         "same path; expected %s, current %s"
         % (seed["partner_task_name"], seed["partner_destination_uri"], pdst))
    need(pt.get("Schedule", {}).get("ScheduleExpression") == seed["partner_schedule"],
         "DataSync task %s had to keep the same schedule; seeded %r, current %r"
         % (seed["partner_task_name"], seed["partner_schedule"],
            pt.get("Schedule", {}).get("ScheduleExpression")))
    need(canon(pt.get("Excludes", [])) == canon(seed["partner_excludes"]),
         "DataSync task %s had to keep the same exclude filters; seeded %s, current %s"
         % (seed["partner_task_name"], canon(seed["partner_excludes"]),
            canon(pt.get("Excludes", []))))
    # everything else the task carried has to survive the rebuild too
    TASK_SKIP = ("TaskArn", "DestinationLocationArn", "DestinationNetworkInterfaceArns",
                 "SourceNetworkInterfaceArns", "ScheduleDetails")
    want_task = {k: v for k, v in strip(seed["partner_snapshot"]).items()
                 if k not in TASK_SKIP}
    cur_task = {k: v for k, v in strip(pt).items() if k not in TASK_SKIP}
    drifted = sorted(k for k in set(want_task) | set(cur_task)
                     if canon(want_task.get(k)) != canon(cur_task.get(k)))
    need(not drifted,
         "DataSync task %s had to keep every setting except where it writes, but these "
         "changed: %s. seeded=%s current=%s"
         % (seed["partner_task_name"], ", ".join(drifted),
            json.dumps({k: want_task.get(k) for k in drifted}, default=str),
            json.dumps({k: cur_task.get(k) for k in drifted}, default=str)))

# ------------------------------------------------- nothing else points at the archive ----
for reg in (REGION, EDGE):
    f = boto3.client("firehose", region_name=reg)
    try:
        names = f.list_delivery_streams(Limit=100)["DeliveryStreamNames"]
    except Exception:
        names = []
    for name in names:
        d = f.describe_delivery_stream(DeliveryStreamName=name)["DeliveryStreamDescription"]
        for dst in d["Destinations"]:
            e = (dst.get("ExtendedS3DestinationDescription")
                 or dst.get("S3DestinationDescription") or {})
            need(e.get("BucketARN") != LEGACY_ARN,
                 "delivery stream %s in %s still has the retired archive %s as its S3 "
                 "destination" % (name, reg, LEGACY))

    d = boto3.client("datasync", region_name=reg)
    for t in d.list_tasks(MaxResults=100).get("Tasks", []):
        det = d.describe_task(TaskArn=t["TaskArn"])
        try:
            uri = d.describe_location_s3(
                LocationArn=det["DestinationLocationArn"])["LocationUri"]
        except Exception:
            continue
        need(not uri.startswith("s3://" + LEGACY + "/"),
             "DataSync task %s in %s still writes into the retired archive: its destination "
             "location is %s" % (t.get("Name"), reg, uri))

    ec2 = boto3.client("ec2", region_name=reg)
    try:
        flows = ec2.describe_flow_logs()["FlowLogs"]
    except Exception:
        flows = []
    for fl in flows:
        need(not fl.get("LogDestination", "").startswith(LEGACY_ARN),
             "flow log %s in %s still delivers into the retired archive: its destination is %s"
             % (fl["FlowLogId"], reg, fl.get("LogDestination")))

edge_flows = boto3.client("ec2", region_name=EDGE).describe_flow_logs()["FlowLogs"]
want_dest = "%s/%s" % (NEW_ARN, seed["flow_prefix"])
FLOW_SKIP = ("FlowLogId", "CreationTime", "LogDestination", "DeliverLogsPermissionArn",
             "Tags", "DeliverLogsStatus", "DeliverLogsErrorMessage")
want_flow = {k: v for k, v in seed["flow_log_snapshot"].items() if k not in FLOW_SKIP}
same = [f for f in edge_flows
        if f.get("LogDestination") == want_dest
        and canon({k: v for k, v in f.items() if k not in FLOW_SKIP}) == canon(want_flow)]
need(same,
     "the flow log on %s was delivering into the retired archive and had to deliver the same "
     "data into the replacement archive at %s with every other setting unchanged. Expected "
     "%s; flow logs now on that VPC are %s"
     % (seed["edge_vpc"], want_dest, canon(want_flow),
        json.dumps([{k: v for k, v in f.items() if k not in FLOW_SKIP[1:]}
                    for f in edge_flows if f.get("ResourceId") == seed["edge_vpc"]],
                   default=str)))

for b in [x["Name"] for x in s3.list_buckets()["Buckets"]]:
    c = boto3.client("s3", region_name=bucket_region(b))
    try:
        cfg = c.get_bucket_replication(Bucket=b)["ReplicationConfiguration"]
    except Exception:
        cfg = None
    for rule in (cfg or {}).get("Rules", []):
        if rule["Destination"]["Bucket"] == LEGACY_ARN:
            need(rule.get("Status") != "Enabled",
                 "bucket %s still has an enabled replication rule %s delivering into the "
                 "retired archive %s" % (b, rule.get("ID"), LEGACY))
    try:
        log = c.get_bucket_logging(Bucket=b).get("LoggingEnabled")
    except Exception:
        log = None
    if log:
        need(log.get("TargetBucket") != LEGACY,
             "bucket %s still writes its server access logs into the retired archive %s under "
             "prefix %r" % (b, LEGACY, log.get("TargetPrefix")))

for reg in (REGION, EDGE):
    ath = boto3.client("athena", region_name=reg)
    try:
        groups = ath.list_work_groups()["WorkGroups"]
    except Exception:
        groups = []
    for g in groups:
        wg = ath.get_work_group(WorkGroup=g["Name"])["WorkGroup"]
        out = (wg.get("Configuration", {}).get("ResultConfiguration", {})
               .get("OutputLocation", "") or "")
        need(not out.startswith("s3://" + LEGACY + "/"),
             "query workgroup %s in %s still parks its results in the retired archive at %s"
             % (g["Name"], reg, out))

wg = boto3.client("athena", region_name=EDGE).get_work_group(
    WorkGroup=seed["athena_workgroup"])["WorkGroup"]
wg_out = (wg.get("Configuration", {}).get("ResultConfiguration", {})
          .get("OutputLocation", "") or "")
need(wg_out == "s3://%s/%s" % (NEW, seed["athena_prefix"]) and wg.get("State") == "ENABLED",
     "query workgroup %s was writing its results into the retired archive under %r and had "
     "to write them into the replacement archive under the same path instead of stopping; it "
     "is now State=%r OutputLocation=%r"
     % (seed["athena_workgroup"], seed["athena_prefix"], wg.get("State"), wg_out))

ingest_log = s3.get_bucket_logging(Bucket=INGEST).get("LoggingEnabled") or {}
need(ingest_log.get("TargetBucket") == NEW
     and ingest_log.get("TargetPrefix") == seed["access_log_prefix"],
     "%s was writing its server access logs into the retired archive under %r and had to "
     "write them into the replacement archive %s under the same prefix instead of stopping; "
     "its logging configuration is now %s"
     % (INGEST, seed["access_log_prefix"], NEW, json.dumps(ingest_log, default=str)))

# ------------------------------------------------- now judge the live probes -------------
WANT = [(COMPLIANCE, probe_in, INGEST, "the compliance feed"),
        (COMPLIANCE, probe_edge, EDGE_INGEST, "the compliance feed"),
        (NEW, probe_in, INGEST, "replication into the replacement archive"),
        (NEW, probe_edge, EDGE_INGEST, "replication into the replacement archive")]
landed = {}
deadline = sent_at + 400
while time.time() < deadline:
    hit = legacy_received()
    if hit:
        ck.fail(hit)
    for bucket, key, where, what in WANT:
        if (bucket, key) not in landed and has_key(s3, bucket, key):
            landed[(bucket, key)] = int(time.time() - sent_at)
    if len(landed) == len(WANT):
        break
    time.sleep(10)

def replication_status(client, bucket, key):
    """Judge-facing evidence: FAILED means S3 tried and was refused, not that it was slow."""
    try:
        return client.head_object(Bucket=bucket, Key=key).get("ReplicationStatus")
    except Exception as exc:
        return "unreadable (%s)" % type(exc).__name__


for bucket, key, where, what in WANT:
    ck.require(
        (bucket, key) in landed,
        "%s from %s must be delivering, but a probe object written to it at %s had not "
        "reached %s after %d seconds. S3 reports ReplicationStatus=%s on the source object, "
        "and the arrivals seen were: %s"
        % (what, where, time.strftime("%H:%M:%SZ", time.gmtime(sent_at)), bucket,
           int(time.time() - sent_at),
           replication_status(s3 if where == INGEST else s3e, where, key),
           ", ".join("%s@%ss" % (b, t) for (b, _), t in sorted(landed.items())) or "none"))

time.sleep(25)
hit = legacy_received()
if hit:
    ck.fail(hit)

if _deferred:
    ck.fail("%d configuration requirement(s) were not met. First: %s"
            % (len(_deferred), _deferred[0]))

ck.ok("nothing writes into %s any more; the compliance feed, the raw delivery stream, the "
      "nightly partner sync, the flow log and the access logs all work against the "
      "replacement archive" % LEGACY)
