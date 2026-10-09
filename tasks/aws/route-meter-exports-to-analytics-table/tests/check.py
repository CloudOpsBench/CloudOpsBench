"""Grader.

Outcome first: the Lambda exporter is INVOKED through its live alias and the delivery stream
it actually writes to is resolved to an S3 location, before anything structural is read. Then
the two exporters that cannot be invoked are read, then the protected resources. No fix shape
is graded - any delivery stream that lands at the catalog table's location counts, including
one the agent created.
"""
import json
import time
import uuid

import checkkit as ck

seed = ck.seed()
fh = ck.client("firehose")
glue = ck.client("glue")
lam = ck.client("lambda")
batch = ck.client("batch")

DB = seed["database"]
TABLE = seed["table"]
FN = seed["function"]
ALIAS = seed["alias"]
JOBDEF = seed["job_definition"]
GLUEJOB = seed["glue_job"]
CBPROJECT = seed["codebuild_project"]
SECONDARY = seed["secondary_region"]
SETTING = "EXPORT_DELIVERY_STREAM"

TARGET = seed["table_snapshot"]["StorageDescriptor"]["Location"].rstrip("/")


def dest_uri(stream):
    """The s3://bucket/prefix a delivery stream lands at, or None if there is no such
    stream (which is also what a value naming something that is not a delivery stream
    resolves to)."""
    if not stream:
        return None
    try:
        d = fh.describe_delivery_stream(
            DeliveryStreamName=stream)["DeliveryStreamDescription"]
    except Exception:
        return None
    for dst in d.get("Destinations", []):
        for key in ("ExtendedS3DestinationDescription", "S3DestinationDescription"):
            cfg = dst.get(key)
            if cfg and cfg.get("BucketARN"):
                bucket = cfg["BucketARN"].split(":::")[-1]
                return ("s3://%s/%s" % (bucket, cfg.get("Prefix", ""))).rstrip("/")
    return None


def where(stream):
    uri = dest_uri(stream)
    if uri is None:
        return "%r, which is not a delivery stream in this account" % (stream,)
    return "%r, which delivers to %s" % (stream, uri)


def latest_env():
    cfg = lam.get_function(FunctionName=FN)["Configuration"]
    return (cfg.get("Environment") or {}).get("Variables", {}).get(SETTING)


def alias_env():
    cfg = lam.get_function(FunctionName=FN, Qualifier=ALIAS)["Configuration"]
    return (cfg.get("Environment") or {}).get("Variables", {}).get(SETTING)


# ---------------------------------------------------------------- 1. functional, runs first
marker = uuid.uuid4().hex[:12]
served = None
delivered = False
invoke_note = "no successful invocation"
for attempt in range(3):
    try:
        r = lam.invoke(FunctionName=FN, Qualifier=ALIAS,
                       Payload=json.dumps({"marker": marker}).encode())
        raw = r["Payload"].read().decode("utf-8", "replace")
        if r.get("FunctionError"):
            invoke_note = ("invoking %s:%s returned %s: %s"
                           % (FN, ALIAS, r["FunctionError"], raw[:300]))
        else:
            delivered = True
            body = json.loads(raw) if raw.strip() else {}
            if isinstance(body, dict) and body.get("stream"):
                served = body["stream"]
                invoke_note = ("invoking %s:%s with marker %s wrote a record to %s"
                               % (FN, ALIAS, marker, where(served)))
            else:
                invoke_note = ("invoking %s:%s succeeded but returned %s, so the stream it "
                               "wrote to is read from the alias configuration instead"
                               % (FN, ALIAS, raw[:200]))
            break
    except Exception as exc:  # transient alias/version propagation, throttles, concurrency
        invoke_note = "invoking %s:%s raised %s" % (FN, ALIAS, exc)
    time.sleep(15)

ck.require(
    delivered,
    "the Lambda exporter cannot deliver at all: %s. Its live alias serves %s. instruction.md "
    "says every exporter must end up delivering into the S3 location "
    "interval_readings reads, and names the Lambda exporter as the one that runs under its "
    "live alias." % (invoke_note, where(alias_env())))

if served is None:
    served = alias_env()
    invoke_note += ("; the %s the live alias serves is %r" % (SETTING, served))

ck.require(
    dest_uri(served) == TARGET,
    "the Lambda exporter still does not deliver into the location the catalog table reads: "
    "%s, while %s.%s reads %s. The alias serves %s and the unpublished $LATEST configuration "
    "holds %r, so a change written with update-function-configuration alone never reaches "
    "what runs. Both facts are readable at any time with `aws lambda get-function "
    "--function-name %s --qualifier %s` and `aws firehose describe-delivery-stream`. "
    "instruction.md says every exporter must end up delivering into the S3 "
    "location interval_readings reads, and names the Lambda exporter as the one that runs "
    "under its live alias."
    % (invoke_note, DB, TABLE, TARGET, where(served), latest_env(), FN, ALIAS))

# ---------------------------------------------------------------- 2. the Batch job definition
jds = batch.describe_job_definitions(
    jobDefinitionName=JOBDEF, status="ACTIVE").get("jobDefinitions", [])
ck.require(
    jds,
    "the Batch job definition %s has no ACTIVE revision left. instruction.md asks for every "
    "exporter to deliver into the location interval_readings reads, not for an exporter to "
    "be removed; it was listable throughout with `aws batch describe-job-definitions "
    "--job-definition-name %s --status ACTIVE`." % (JOBDEF, JOBDEF))
latest_jd = max(jds, key=lambda j: j["revision"])
jd_env = {e.get("name"): e.get("value")
          for e in latest_jd.get("containerProperties", {}).get("environment", [])}
jd_stream = jd_env.get(SETTING)
ck.require(
    dest_uri(jd_stream) == TARGET,
    "the Batch exporter still routes elsewhere: revision %d of job definition %s (the latest "
    "ACTIVE one, which is what a submission by name runs) sets %s to %s, while %s.%s reads "
    "%s. The value is in `aws batch describe-job-definitions --job-definition-name %s "
    "--status ACTIVE` and the destination in `aws firehose describe-delivery-stream`, both "
    "available for the whole rollout. instruction.md puts every exporter carrying %s in "
    "scope." % (latest_jd["revision"], JOBDEF, SETTING, where(jd_stream), DB, TABLE, TARGET,
                JOBDEF, SETTING))

# ---------------------------------------------------------------- 3. the Glue job
job = glue.get_job(JobName=GLUEJOB)["Job"]
args = dict(job.get("DefaultArguments") or {})
args.update(job.get("NonOverridableArguments") or {})  # non-overridable wins at run time
glue_stream = args.get("--" + SETTING, args.get(SETTING))
ck.require(
    dest_uri(glue_stream) == TARGET,
    "the Glue exporter still routes elsewhere: job %s passes --%s = %s, while %s.%s reads "
    "%s. The argument is in `aws glue get-job --job-name %s` and the destination in `aws "
    "firehose describe-delivery-stream`, both available for the whole rollout. "
    "instruction.md puts every exporter carrying %s in scope."
    % (GLUEJOB, SETTING, where(glue_stream), DB, TABLE, TARGET, GLUEJOB, SETTING))

# ------------------------------------------- 4. the exporter in the other region
cb = ck.client("codebuild", region_name=SECONDARY)
projects = cb.batch_get_projects(names=[CBPROJECT]).get("projects", [])
ck.require(
    projects,
    "the CodeBuild exporter %s is gone from %s. instruction.md asks for every exporter "
    "carrying %s to deliver into the location interval_readings reads, not for one to be "
    "removed; it was listable for the whole rollout with `aws codebuild list-projects "
    "--region %s`." % (CBPROJECT, SECONDARY, SETTING, SECONDARY))
cb_env = {v.get("name"): v.get("value")
          for v in projects[0].get("environment", {}).get("environmentVariables", [])}
cb_stream = cb_env.get(SETTING)
ck.require(
    dest_uri(cb_stream) == TARGET,
    "the CodeBuild exporter still routes elsewhere: project %s in %s sets %s to %s, while "
    "%s.%s reads %s. Nothing in %s refers to this project, but it was listable for the whole "
    "rollout with `aws codebuild list-projects --region %s` and readable with `aws codebuild "
    "batch-get-projects`, the same pair of calls the rollout already made against the other "
    "exporters in its own region. instruction.md puts EVERY exporter carrying %s in scope and "
    "never limits that to one region."
    % (CBPROJECT, SECONDARY, SETTING, where(cb_stream), DB, TABLE, TARGET, seed["region"],
       SECONDARY, SETTING))

# ------------------------------------------- 4. the stream can actually write that location
iam = ck.client("iam")
s3 = ck.client("s3")
bucket, _, key_prefix = TARGET.split("://", 1)[1].partition("/")
key_prefix = key_prefix.rstrip("/")
TARGET_OBJECTS = "arn:aws:s3:::%s/%s/*" % (bucket, key_prefix)
TARGET_BUCKET = "arn:aws:s3:::%s" % bucket
# What Firehose itself needs to put an object at a destination, split by ARN level.
NEEDED = [(TARGET_BUCKET, ["s3:GetBucketLocation", "s3:ListBucket",
                           "s3:ListBucketMultipartUploads"]),
          (TARGET_OBJECTS, ["s3:PutObject", "s3:AbortMultipartUpload"])]


def bucket_policy():
    """The destination bucket's own policy, so a repair written there instead of on the
    role is evaluated too rather than reported as a denial."""
    try:
        return s3.get_bucket_policy(Bucket=bucket)["Policy"]
    except Exception:
        return None


POLICY = bucket_policy()


def denied_actions(role):
    """Actions Firehose needs that this role is not granted, identity policies and the
    destination bucket policy taken together."""
    out = []
    for resource, actions in NEEDED:
        kwargs = {"PolicySourceArn": role, "ActionNames": actions,
                  "ResourceArns": [resource]}
        if POLICY:
            kwargs["ResourcePolicy"] = POLICY
            kwargs["ResourceOwner"] = "arn:aws:iam::%s:root" % ck.account_id()
            kwargs["CallerArn"] = role
        for r in iam.simulate_principal_policy(**kwargs)["EvaluationResults"]:
            if r["EvalDecision"] != "allowed":
                out.append("%s on %s is %s" % (r["EvalActionName"], resource,
                                               r["EvalDecision"]))
    return out


def delivered(stream, deadline):
    """Ground truth: put a record on the stream and watch for an object at the location.
    Only reached when the authorization read says something is missing, so a correct fix
    never pays this wait."""
    started = time.time()
    try:
        fh.put_record(DeliveryStreamName=stream,
                      Record={"Data": json.dumps({"meter_id": marker, "read_ts":
                                                  "probe", "kwh": 1.0}).encode() + b"\n"})
    except Exception:
        return False
    while time.time() - started < deadline:
        time.sleep(15)
        listing = s3.list_objects_v2(Bucket=bucket, Prefix=key_prefix + "/")
        for obj in listing.get("Contents", []):
            if obj["LastModified"].timestamp() >= started - 5:
                return True
    return False


def buffer_seconds(stream):
    d = fh.describe_delivery_stream(DeliveryStreamName=stream)["DeliveryStreamDescription"]
    for dst in d.get("Destinations", []):
        for k in ("ExtendedS3DestinationDescription", "S3DestinationDescription"):
            hints = dst.get(k, {}).get("BufferingHints")
            if hints:
                return hints.get("IntervalInSeconds", 60)
    return 60


def delivery_role(stream):
    d = fh.describe_delivery_stream(DeliveryStreamName=stream)["DeliveryStreamDescription"]
    for dst in d.get("Destinations", []):
        for k in ("ExtendedS3DestinationDescription", "S3DestinationDescription"):
            if dst.get(k, {}).get("RoleARN"):
                return dst[k]["RoleARN"]
    return None


for stream in sorted({served, jd_stream, glue_stream, cb_stream}):
    role = delivery_role(stream)
    ck.require(role, "delivery stream %r reports no delivery role, so nothing it receives "
                     "can reach %s." % (stream, TARGET))
    missing = denied_actions(role)
    if not missing:
        continue  # fully authorised; no need to spend wall clock proving it
    wait = min(buffer_seconds(stream) + 60, 180)
    ck.require(
        delivered(stream, wait),
        "the exporters now name delivery stream %r, which is configured for %s but does not "
        "deliver there. Its delivery role %s is missing %s (evaluated against its identity "
        "policies and the destination bucket policy together), and a record put on the "
        "stream produced no new object under %s/ within %ds, against a buffering interval of "
        "%ds. The role is named in the stream's own description, its grants are readable "
        "with `aws iam get-role-policy`, and the same put-and-look test the grader just ran is "
        "available to the rollout at any time. instruction.md says an exporter counts as "
        "delivering only if the records it sends actually reach that location."
        % (stream, TARGET, role.split("/")[-1], "; ".join(missing), key_prefix, wait,
           buffer_seconds(stream)))

# ---------------------------------------------------------------- 6. protected: the streams
for name, snapshot in seed["stream_snapshots"].items():
    try:
        desc = fh.describe_delivery_stream(
            DeliveryStreamName=name)["DeliveryStreamDescription"]
    except Exception as exc:
        ck.fail("delivery stream %s is gone (%s). instruction.md says no delivery stream may "
                "be deleted." % (name, exc))
    ck.require(
        desc["DeliveryStreamStatus"] == "ACTIVE",
        "delivery stream %s is %s, not ACTIVE. instruction.md says no delivery stream may be "
        "deleted and none of their destination settings may be altered."
        % (name, desc["DeliveryStreamStatus"]))
    def addressing(destinations):
        stripped = json.loads(json.dumps(destinations, default=str))
        for dst in stripped:
            for k in ("ExtendedS3DestinationDescription", "S3DestinationDescription"):
                if isinstance(dst.get(k), dict):
                    dst[k].pop("RoleARN", None)
        return stripped

    now = addressing(desc.get("Destinations", []))
    ck.require(
        now == addressing(snapshot),
        "delivery stream %s no longer writes where it was seeded to write. Seeded: %s. Now: "
        "%s. instruction.md says no delivery stream may be pointed at a different bucket or "
        "prefix; repointing an existing stream is not an accepted way to satisfy the routing "
        "requirement." % (name, json.dumps(addressing(snapshot))[:600], json.dumps(now)[:600]))

# ---------------------------------------------------------------- 7. protected: the table
VOLATILE = {"CreateTime", "UpdateTime", "VersionId", "CreatedBy", "LastAccessTime",
            "LastAnalyzedTime", "IsRegisteredWithLakeFormation", "CatalogId",
            "DatabaseName", "Status", "FederatedTable"}


def definition(table):
    whole = json.loads(json.dumps(table, default=str))
    return {k: v for k, v in whole.items() if k not in VOLATILE}


tbl = glue.get_table(DatabaseName=DB, Name=TABLE)["Table"]
snap = seed["table_snapshot"]
ck.require(
    definition(tbl) == definition(snap),
    "the catalog table %s.%s was modified. Seeded: %s. Now: %s. instruction.md says the "
    "interval_readings table definition must stay exactly as it is, so moving the table to "
    "where the exporters already wrote is not an accepted fix."
    % (DB, TABLE, json.dumps(definition(snap))[:700], json.dumps(definition(tbl))[:700]))

ck.ok("every exporter delivers into %s, and both delivery streams and the "
      "%s.%s table definition are untouched" % (TARGET, DB, TABLE))
