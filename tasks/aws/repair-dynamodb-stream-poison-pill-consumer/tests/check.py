#!/usr/bin/env python3
"""Check the repaired DynamoDB stream consumer.

Passes when the protected resources and configuration match seed_state.json, the existing
event-source mapping reports partial batch failures, bisects on error, retries twice, caps
record age at 3600 seconds and sends failures to the archive bucket, and direct invocations
handle poison records, replays, deletes, conflicts and transaction groups correctly.
"""
import concurrent.futures, hashlib, io, json, os, secrets, subprocess, sys, tempfile, time, urllib.request, uuid, zipfile


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def aws(args, check=True):
    p=subprocess.run(["aws",*args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode:
        fail(f"AWS command failed: aws {' '.join(args)} :: {p.stderr.strip()}")
    return p


def aws_json(args, check=True):
    p=aws([*args,"--output","json"], check=check)
    if not check and p.returncode:
        return None
    try:
        return json.loads(p.stdout or "{}")
    except Exception:
        fail(f"invalid JSON from aws {' '.join(args)}")


def h(v):
    return hashlib.sha256(json.dumps(v,sort_keys=True,separators=(",",":")).encode()).hexdigest()


def normalized_function_config(cfg):
    x=dict(cfg)
    v=x.get("VpcConfig") or {}
    return {
      "Role":x.get("Role"), "Runtime":x.get("Runtime"), "Handler":x.get("Handler"),
      "Description":x.get("Description",""), "Timeout":x.get("Timeout"), "MemorySize":x.get("MemorySize"),
      "Environment":(x.get("Environment") or {}).get("Variables",{}), "KMSKeyArn":x.get("KMSKeyArn",""),
      "TracingMode":(x.get("TracingConfig") or {}).get("Mode"),
      "Layers":[z.get("Arn") for z in x.get("Layers",[])],
      "DeadLetterConfig":x.get("DeadLetterConfig") or {}, "FileSystemConfigs":x.get("FileSystemConfigs") or [],
      "PackageType":x.get("PackageType"), "Architectures":x.get("Architectures") or [],
      "EphemeralStorage":x.get("EphemeralStorage") or {},
      "SnapStartApplyOn":(x.get("SnapStart") or {}).get("ApplyOn"),
      "LoggingConfig":x.get("LoggingConfig") or {},
      "VpcConfig":{k:v.get(k) for k in ["VpcId","SubnetIds","SecurityGroupIds","Ipv6AllowedForDualStack"] if k in v},
    }


def package_snapshot(function_name):
    gf=aws_json(["lambda","get-function","--function-name",function_name])
    url=((gf.get("Code") or {}).get("Location"))
    if not url:
        fail("Lambda deployment package location is unavailable")
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            raw=r.read()
        with zipfile.ZipFile(io.BytesIO(raw),"r") as z:
            names=sorted(x for x in z.namelist() if not x.endswith("/"))
            if "lambda_function.py" not in names:
                fail("Lambda package no longer contains lambda_function.py")
            assets={}
            for name in names:
                if name == "lambda_function.py":
                    continue
                assets[name]=hashlib.sha256(z.read(name)).hexdigest()
    except Exception as exc:
        fail(f"could not inspect Lambda deployment package: {exc}")
    return h(names), h(assets)


if not os.path.exists("seed_state.json"):
    fail("seed_state.json is missing")
S=json.load(open("seed_state.json"))

# Protected resources and configuration.
src=aws_json(["dynamodb","describe-table","--table-name",S["source_table"]])["Table"]
if src.get("TableArn") != S["source_table_arn"] or src.get("TableId") != S["source_table_id"]:
    fail("source DynamoDB table identity changed")
if src.get("LatestStreamArn") != S["stream_arn"]:
    fail("source stream ARN changed; stream must be preserved in place")
if src.get("KeySchema",[]) != [{"AttributeName":"event_id","KeyType":"HASH"}]:
    fail("source table key schema changed")
ss=src.get("StreamSpecification") or {}
if ss.get("StreamEnabled") is not True or ss.get("StreamViewType") != S["stream_view_type"]:
    fail("source stream configuration changed; NEW_AND_OLD_IMAGES must be preserved")
source_scan=aws_json(["dynamodb","scan","--table-name",S["source_table"],"--consistent-read"])
source_items=sorted(source_scan.get("Items",[]), key=lambda x:json.dumps(x,sort_keys=True,separators=(",",":")))
if len(source_items) != S["source_item_count"] or h(source_items) != S["source_items_sha256"]:
    fail("source-table contents changed; live stream records must not be created for repair testing")

out=aws_json(["dynamodb","describe-table","--table-name",S["processed_table"]])["Table"]
if out.get("TableArn") != S["processed_table_arn"] or out.get("TableId") != S["processed_table_id"]:
    fail("processed-state DynamoDB table identity changed")
if out.get("KeySchema",[]) != [{"AttributeName":"event_id","KeyType":"HASH"}]:
    fail("processed-state table key schema changed")

receipt_table=aws_json(["dynamodb","describe-table","--table-name",S["receipt_table"]])["Table"]
if receipt_table.get("TableArn") != S["receipt_table_arn"] or receipt_table.get("TableId") != S["receipt_table_id"]:
    fail("mutation-receipt DynamoDB table identity changed")
if receipt_table.get("KeySchema",[]) != [{"AttributeName":"event_id","KeyType":"HASH"},{"AttributeName":"mutation_id","KeyType":"RANGE"}]:
    fail("mutation-receipt table key schema changed")

compat_receipts=aws_json(["dynamodb","scan","--table-name",S["receipt_table"],"--consistent-read","--filter-expression","begins_with(event_id, :p)","--expression-attribute-values",json.dumps({":p":{"S":"compat-"}})]).get("Items",[])
compat_receipts=sorted(compat_receipts,key=lambda x:json.dumps(x,sort_keys=True,separators=(",",":")))
if h(compat_receipts) != S["receipt_compat_sha256"]:
    fail("frozen compat-* mutation receipt examples changed")

cfg=aws_json(["lambda","get-function-configuration","--function-name",S["function_name"]])
if cfg.get("FunctionArn") != S["function_arn"]:
    fail("Lambda function identity changed")
if h(normalized_function_config(cfg)) != S["function_config_sha256"]:
    fail("non-code Lambda configuration changed; only the deployment package is repairable")
if h(aws_json(["lambda","get-function-concurrency","--function-name",S["function_name"]])) != S["function_concurrency_sha256"]:
    fail("Lambda reserved-concurrency configuration changed")
if h(aws_json(["lambda","list-tags","--resource",S["function_arn"]]).get("Tags",{})) != S["function_tags_sha256"]:
    fail("Lambda function tags changed")
versions=[]
for v in aws_json(["lambda","list-versions-by-function","--function-name",S["function_name"]]).get("Versions",[]):
    if v.get("Version") == "$LATEST":
        continue
    versions.append({k:v.get(k) for k in ["Version","FunctionArn","CodeSha256","Description"]})
versions.sort(key=lambda x:int(x["Version"]))
if h(versions) != S["published_versions_sha256"]:
    fail("published Lambda version set changed; repair $LATEST only and do not publish/delete versions")
aliases=[{k:a.get(k) for k in ["Name","AliasArn","FunctionVersion","Description","RoutingConfig"]} for a in aws_json(["lambda","list-aliases","--function-name",S["function_name"]]).get("Aliases",[])]
aliases.sort(key=lambda x:x["Name"])
if h(aliases) != S["aliases_sha256"]:
    fail("Lambda alias set/routing changed; COMPAT compatibility alias is frozen")

entry_hash,asset_hash=package_snapshot(S["function_name"])
if entry_hash != S["package_entries_sha256"] or asset_hash != S["package_assets_sha256"]:
    fail("non-lambda_function.py deployment-package entries changed; compatibility assets are frozen")

role=aws_json(["iam","get-role","--role-name",S["role_name"]]).get("Role",{})
if role.get("RoleId") != S["role_id"]:
    fail("Lambda execution role identity changed")
role_state={k:role.get(k) for k in ["Arn","Path","MaxSessionDuration","PermissionsBoundary","Tags"]}
if h(role_state) != S["role_state_sha256"]:
    fail("Lambda execution-role non-policy state changed")
if h(role.get("AssumeRolePolicyDocument",{})) != S["role_trust_sha256"]:
    fail("Lambda execution-role trust policy changed")
inline_names=sorted(aws_json(["iam","list-role-policies","--role-name",S["role_name"]]).get("PolicyNames",[]))
if h(inline_names) != S["role_inline_names_sha256"]:
    fail("Lambda execution-role inline-policy set changed")
attached=sorted(x.get("PolicyArn") for x in aws_json(["iam","list-attached-role-policies","--role-name",S["role_name"]]).get("AttachedPolicies",[]) if x.get("PolicyArn"))
if h(attached) != S["role_attached_arns_sha256"]:
    fail("Lambda execution-role managed-policy attachment set changed")
rp=aws_json(["iam","get-role-policy","--role-name",S["role_name"],"--policy-name",S["role_policy_name"]]).get("PolicyDocument",{})
if h(rp) != S["role_policy_sha256"]:
    fail("frozen Lambda execution-role inline policy changed")

if aws(["s3api","head-bucket","--bucket",S["bucket"]], check=False).returncode != 0:
    fail("preserved S3 failure-archive bucket is missing")
tags=aws_json(["s3api","get-bucket-tagging","--bucket",S["bucket"]]).get("TagSet",[])
if {x.get("Key"):x.get("Value") for x in tags}.get("CloudOpTask") != "ddb-stream-poison":
    fail("preserved S3 failure-archive bucket task tag changed")
objects=[{k:o.get(k) for k in ["Key","ETag","Size","StorageClass"]} for o in aws_json(["s3api","list-objects-v2","--bucket",S["bucket"]]).get("Contents",[])]
objects.sort(key=lambda x:x["Key"])
if h(objects) != S["archive_objects_sha256"]:
    fail("failure-archive object set changed; do not generate synthetic archived failures during repair testing")

# Event-source mapping settings.
all_maps=aws_json(["lambda","list-event-source-mappings","--function-name",S["function_name"]]).get("EventSourceMappings",[])
if len(all_maps) != 1:
    fail(f"expected exactly one preserved event-source mapping for function, found {len(all_maps)}")
if all_maps[0].get("UUID") != S["event_source_mapping_uuid"]:
    fail("event-source mapping was recreated instead of repaired in place")
source_maps=aws_json(["lambda","list-event-source-mappings","--event-source-arn",S["stream_arn"]]).get("EventSourceMappings",[])
if len(source_maps) != 1 or source_maps[0].get("UUID") != S["event_source_mapping_uuid"]:
    fail("source stream gained a replacement/additional consumer mapping")

esm=None
for _ in range(30):
    esm=aws_json(["lambda","get-event-source-mapping","--uuid",S["event_source_mapping_uuid"]])
    if esm.get("State") == "Enabled":
        break
    time.sleep(1)
if esm.get("State") != "Enabled":
    fail(f"event-source mapping is not Enabled (state={esm.get('State')})")
if esm.get("EventSourceArn") != S["stream_arn"] or esm.get("FunctionArn") != S["function_arn"]:
    fail("event-source mapping source/function changed")
if esm.get("StartingPosition") != S["starting_position"]:
    fail("event-source mapping starting position changed")
if esm.get("BatchSize") != S["batch_size"] or esm.get("ParallelizationFactor",1) != S["parallelization_factor"]:
    fail("event-source mapping batch size or parallelization factor changed")
if esm.get("MaximumBatchingWindowInSeconds",0) != S["maximum_batching_window"]:
    fail("event-source mapping batching window changed")
if esm.get("TumblingWindowInSeconds",0) != S["tumbling_window"]:
    fail("event-source mapping tumbling-window setting changed")
if h(esm.get("FilterCriteria") or {}) != S["filter_criteria_sha256"]:
    fail("event-source mapping FilterCriteria changed; poison records must not be hidden by filtering")
drop={"UUID","LastModified","LastProcessingResult","State","StateTransitionReason","DestinationConfig","MaximumRecordAgeInSeconds","BisectBatchOnFunctionError","MaximumRetryAttempts","FunctionResponseTypes"}
esm_static={k:v for k,v in esm.items() if k not in drop}
if h(esm_static) != S["event_source_static_sha256"]:
    fail("a frozen event-source mapping field changed (including scaling/poller/static settings)")
if "ReportBatchItemFailures" not in (esm.get("FunctionResponseTypes") or []):
    fail("ReportBatchItemFailures is not enabled")
if esm.get("BisectBatchOnFunctionError") is not True:
    fail("BisectBatchOnFunctionError must be enabled")
if esm.get("MaximumRetryAttempts") != 2:
    fail(f"MaximumRetryAttempts must be exactly 2, got {esm.get('MaximumRetryAttempts')}")
if esm.get("MaximumRecordAgeInSeconds") != 3600:
    fail(f"MaximumRecordAgeInSeconds must be exactly 3600, got {esm.get('MaximumRecordAgeInSeconds')}")
dest=((esm.get("DestinationConfig") or {}).get("OnFailure") or {}).get("Destination")
if dest != S["bucket_arn"]:
    fail("OnFailure destination must be the preserved S3 full-payload archive bucket")

for _ in range(30):
    cfg=aws_json(["lambda","get-function-configuration","--function-name",S["function_name"]])
    if cfg.get("LastUpdateStatus") == "Successful" and cfg.get("State") == "Active":
        break
    if cfg.get("LastUpdateStatus") == "Failed":
        fail("Lambda function update is in Failed state")
    time.sleep(1)
else:
    fail("Lambda function update did not settle")


def image(event_id,payload,revision,poison=False,tx=None):
    x={
        "event_id":{"S":event_id},
        "payload":{"S":payload},
        "revision":{"N":str(revision)},
        "poison":{"BOOL":bool(poison)},
    }
    if tx is not None:
        x["tx_id"]={"S":tx[0]}
        x["tx_index"]={"N":str(tx[1])}
        x["tx_size"]={"N":str(tx[2])}
    return x


def rec_upsert(event_id,payload,revision,poison,seq,name="MODIFY",old=None,key_id=None,tx=None):
    d={
      "Keys":{"event_id":{"S":key_id if key_id is not None else event_id}},
      "NewImage":image(event_id,payload,revision,poison,tx),
      "SequenceNumber":str(seq),
      "SizeBytes":64,
      "StreamViewType":"NEW_AND_OLD_IMAGES"
    }
    if old is not None:
        old_id=old[3] if len(old)>3 else event_id
        d["OldImage"]=image(old_id,old[0],old[1],old[2] if len(old)>2 else False)
    return {
      "eventID":f"evt-{event_id}-{seq}","eventName":name,"eventSource":"aws:dynamodb",
      "awsRegion":S["region"],"eventSourceARN":S["stream_arn"],"dynamodb":d
    }


def rec_remove(event_id,payload,revision,seq,key_id=None,old_id=None,poison=False,tx=None):
    return {
      "eventID":f"evt-{event_id}-{seq}","eventName":"REMOVE","eventSource":"aws:dynamodb",
      "awsRegion":S["region"],"eventSourceARN":S["stream_arn"],
      "dynamodb":{
        "Keys":{"event_id":{"S":key_id if key_id is not None else event_id}},
        "OldImage":image(old_id if old_id is not None else event_id,payload,revision,poison,tx),
        "SequenceNumber":str(seq),"SizeBytes":48,"StreamViewType":"NEW_AND_OLD_IMAGES"
      }
    }


def delete_item(event_id):
    aws(["dynamodb","delete-item","--table-name",S["processed_table"],"--key",json.dumps({"event_id":{"S":event_id}})])


def get_item(event_id):
    j=aws_json(["dynamodb","get-item","--table-name",S["processed_table"],"--key",json.dumps({"event_id":{"S":event_id}}),"--consistent-read"])
    return j.get("Item")

def receipt_key(event_id,kind,revision,seq):
    prefix="L" if kind=="live" else "D"
    return {"event_id":{"S":event_id},"mutation_id":{"S":f"{prefix}#{revision}#{seq}"}}


def expected_receipt(event_id,kind,revision,seq,payload=None):
    x={"event_id":{"S":event_id},"mutation_id":{"S":f"{'L' if kind=='live' else 'D'}#{revision}#{seq}"},
       "kind":{"S":kind},"revision":{"N":str(revision)},"sequence_number":{"S":str(seq)}}
    if kind=="live": x["payload"]={"S":payload}
    return x


def get_receipt(event_id,kind,revision,seq):
    return aws_json(["dynamodb","get-item","--table-name",S["receipt_table"],"--key",json.dumps(receipt_key(event_id,kind,revision,seq)),"--consistent-read"]).get("Item")


def put_receipt_raw(item):
    aws(["dynamodb","put-item","--table-name",S["receipt_table"],"--item",json.dumps(item)])


def expect_receipt(event_id,kind,revision,seq,payload=None):
    want=expected_receipt(event_id,kind,revision,seq,payload)
    got=get_receipt(event_id,kind,revision,seq)
    if got != want:
        fail(f"mutation receipt mismatch for {event_id} {kind} rev{revision}: expected {want}, got {got}")


def expect_no_receipt(event_id,kind,revision,seq):
    if get_receipt(event_id,kind,revision,seq) is not None:
        fail(f"failed/stale mutation unexpectedly wrote a receipt for {event_id} {kind} rev{revision}")


def put_started(event_id,payload,revision,seq):
    item={
      "event_id":{"S":event_id},"status":{"S":"started"},"payload":{"S":payload},
      "revision":{"N":str(revision)},"sequence_number":{"S":str(seq)}
    }
    aws(["dynamodb","put-item","--table-name",S["processed_table"],"--item",json.dumps(item)])


def lambda_call(payload):
    raw_payload=json.dumps(payload,separators=(",",":"))
    with tempfile.NamedTemporaryFile(prefix="ddb-poison-invoke-", delete=False) as f:
        outpath=f.name
    try:
        p=subprocess.run(
            ["aws","lambda","invoke","--function-name",S["function_name"],
             "--cli-binary-format","raw-in-base64-out","--payload",raw_payload,outpath,"--output","json"],
            text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE
        )
        if p.returncode:
            raise RuntimeError(f"aws lambda invoke failed: {p.stderr.strip()}")
        meta=json.loads(p.stdout or "{}")
        raw=open(outpath,"rb").read().decode("utf-8","replace")
        try:
            body=json.loads(raw or "null")
        except Exception:
            raise RuntimeError(f"Lambda returned non-JSON payload: {raw[:500]}")
        return meta,body
    finally:
        try: os.unlink(outpath)
        except OSError: pass


def invoke(records):
    try:
        meta,body=lambda_call({"Records":records})
    except Exception as exc:
        fail(str(exc))
    if meta.get("FunctionError"):
        fail(f"Lambda raised a whole-invocation error instead of representable partial failures: {body}")
    if not isinstance(body,dict) or not isinstance(body.get("batchItemFailures"),list):
        fail(f"Lambda must return a batchItemFailures list, got {body}")
    return body


def invoke_expect_error(records):
    try:
        meta,body=lambda_call({"Records":records})
    except Exception as exc:
        fail(str(exc))
    if not meta.get("FunctionError"):
        fail(f"unidentifiable failed record must fail the whole invocation, got {body}")


def failure_ids(body):
    vals=[]
    for x in body.get("batchItemFailures",[]):
        if not isinstance(x,dict) or set(x) != {"itemIdentifier"} or not isinstance(x.get("itemIdentifier"),str) or not x["itemIdentifier"]:
            fail(f"invalid batchItemFailures entry: {x}")
        vals.append(x["itemIdentifier"])
    if len(vals) != len(set(vals)):
        fail(f"batchItemFailures contains duplicate identifiers: {vals}")
    return set(vals)


def expect_failures(body,*ids):
    got=failure_ids(body)
    want=set(map(str,ids))
    if got != want:
        fail(f"expected failure SequenceNumbers {sorted(want)}, got {sorted(got)}")


def canonical_live(item,event_id,payload,revision,seq):
    expected={
      "event_id":{"S":event_id},"status":{"S":"processed"},"payload":{"S":payload},
      "revision":{"N":str(revision)},"sequence_number":{"S":str(seq)}
    }
    if item != expected:
        fail(f"live state for {event_id} is not exact canonical shape: expected {expected}, got {item}")


def canonical_deleted(item,event_id,revision,seq):
    expected={
      "event_id":{"S":event_id},"status":{"S":"deleted"},
      "revision":{"N":str(revision)},"sequence_number":{"S":str(seq)}
    }
    if item != expected:
        fail(f"deleted state for {event_id} is not exact tombstone shape: expected {expected}, got {item}")


# The compat-v1 invocation path must still return the same result after the repair.
compat_id=f"compat-{uuid.uuid4().hex[:12]}"
compat_values=[{"k":"b","v":2},{"k":"a","v":[3,1]},f"x-{secrets.token_hex(4)}"]
try:
    meta,compat_body=lambda_call({"contract":"compat-v1","request_id":compat_id,"values":compat_values})
except Exception as exc:
    fail(str(exc))
if meta.get("FunctionError"):
    fail(f"compat-v1 behavior regressed: {compat_body}")
canon=json.dumps(compat_values,sort_keys=True,separators=(",",":"))
expected_compat={
    "contract":"compat-v1",
    "request_id":compat_id,
    "count":len(compat_values),
    "digest":hashlib.sha256(("jc-ddb-compat-2026|"+canon).encode()).hexdigest(),
}
if compat_body != expected_compat:
    fail(f"compat-v1 behavior changed: expected {expected_compat}, got {compat_body}")


tag=uuid.uuid4().hex[:10]
base=10**22 + secrets.randbelow(10**8)*100
seq=lambda n: str(base+n)
entity=f"grader-{tag}-entity"
other=f"grader-{tag}-other"
poison_only=f"grader-{tag}-poison-only"
for x in (entity,other,poison_only): delete_item(x)

# Recover artifacts left by the broken handler.
marker_good=f"grader-{tag}-marker-good"
marker_bad=f"grader-{tag}-marker-poison"
delete_item(marker_good); delete_item(marker_bad)
put_started(marker_good,"marker-ok",2,seq(40))
rm=invoke([rec_upsert(marker_good,"marker-ok",2,False,seq(40),name="INSERT")])
expect_failures(rm)
canonical_live(get_item(marker_good),marker_good,"marker-ok",2,seq(40))
expect_receipt(marker_good,"live",2,seq(40),"marker-ok")
put_started(marker_bad,"marker-bad",1,seq(41))
rm2=invoke([rec_upsert(marker_bad,"marker-bad",1,True,seq(41),name="INSERT")])
expect_failures(rm2,seq(41))
if get_item(marker_bad) is not None:
    fail("exact poison retry left the legacy started marker in processed state")
expect_no_receipt(marker_bad,"live",1,seq(41))

marker_late=f"grader-{tag}-marker-late"
delete_item(marker_late)
put_started(marker_late,"bad5",5,seq(42))
advance=rec_upsert(marker_late,"good6",6,False,seq(43),name="MODIFY",old=("bad5",5,True))
rm3=invoke([advance]); expect_failures(rm3)
canonical_live(get_item(marker_late),marker_late,"good6",6,seq(43))
old_poison=rec_upsert(marker_late,"bad5",5,True,seq(42),name="MODIFY",old=("good4",4,False))
rm4=invoke([old_poison]); expect_failures(rm4,seq(42))
canonical_live(get_item(marker_late),marker_late,"good6",6,seq(43))

# Revision progress continues around poison; poison remains failed.
batch1=[
    rec_upsert(entity,"v1",1,False,seq(1),name="INSERT"),
    rec_upsert(entity,"v2-bad",2,True,seq(2),old=("v1",1,False)),
    rec_upsert(entity,"v3",3,False,seq(3),old=("v2-bad",2,True)),
    rec_upsert(poison_only,"bad-alone",1,True,seq(4),name="INSERT"),
    rec_upsert(other,"other-v1",1,False,seq(5),name="INSERT"),
]
r1=invoke(batch1)
expect_failures(r1,seq(2),seq(4))
canonical_live(get_item(entity),entity,"v3",3,seq(3))
canonical_live(get_item(other),other,"other-v1",1,seq(5))
expect_receipt(entity,"live",1,seq(1),"v1")
expect_receipt(entity,"live",3,seq(3),"v3")
expect_receipt(other,"live",1,seq(5),"other-v1")
expect_no_receipt(entity,"live",2,seq(2))
if get_item(poison_only) is not None:
    fail("standalone poison record left processed/idempotency state")

# Full checkpoint replay must be stable and keep poison failed.
before_entity=get_item(entity); before_other=get_item(other)
r2=invoke(batch1)
expect_failures(r2,seq(2),seq(4))
if get_item(entity) != before_entity or get_item(other) != before_other or get_item(poison_only) is not None:
    fail("checkpoint replay changed materialized state")

# Equal live order with different content/sequence is a conflict.
same_live=rec_upsert(entity,"v3-CONFLICT",3,False,seq(6),old=("v2-bad",2,True))
r3=invoke([same_live])
expect_failures(r3,seq(6))
canonical_live(get_item(entity),entity,"v3",3,seq(3))

# REMOVE at the same revision outranks live revision 3.
remove3=rec_remove(entity,"v3",3,seq(7))
r4=invoke([remove3])
expect_failures(r4)
canonical_deleted(get_item(entity),entity,3,seq(7))
expect_receipt(entity,"delete",3,seq(7))

# Replaying the lower-order live revision 3 after the tombstone is a stale success, not a resurrection or conflict.
r4b=invoke([rec_upsert(entity,"v3",3,False,seq(3),name="MODIFY",old=("v2-bad",2,True))])
expect_failures(r4b)
canonical_deleted(get_item(entity),entity,3,seq(7))
# Exact REMOVE replay is no-op; another REMOVE at equal order is a conflict.
r4c=invoke([remove3]); expect_failures(r4c)
remove3_conflict=rec_remove(entity,"v3",3,seq(8))
r4d=invoke([remove3_conflict]); expect_failures(r4d,seq(8))
canonical_deleted(get_item(entity),entity,3,seq(7))

# REMOVE can carry poison in OldImage too; it must fail closed and write neither state nor receipt.
poison_remove=rec_remove(entity,"v3",4,seq(81),poison=True)
r4e=invoke([poison_remove]); expect_failures(r4e,seq(81))
canonical_deleted(get_item(entity),entity,3,seq(7))
expect_no_receipt(entity,"delete",4,seq(81))

# Higher revision recreates after tombstone.
rev4=rec_upsert(entity,"v4-recreated",4,False,seq(9),name="INSERT")
r5=invoke([rev4]); expect_failures(r5)
canonical_live(get_item(entity),entity,"v4-recreated",4,seq(9))

# Poison and intrinsic conflicts are permanent failures even after later state advances.
poison5=rec_upsert(entity,"v5-poison",5,True,seq(10),name="MODIFY",old=("v4-recreated",4,False))
rev6=rec_upsert(entity,"v6",6,False,seq(11),name="MODIFY",old=("v5-poison",5,True))
intrinsic=rec_upsert(entity,"v6-conflict",6,False,seq(12),name="MODIFY",old=("v6",6,False))
rev7=rec_upsert(entity,"v7",7,False,seq(13),name="MODIFY",old=("v6",6,False))
r6=invoke([poison5,rev6,intrinsic,rev7])
expect_failures(r6,seq(10),seq(12))
canonical_live(get_item(entity),entity,"v7",7,seq(13))
r6b=invoke([poison5,intrinsic])
expect_failures(r6b,seq(10),seq(12))
canonical_live(get_item(entity),entity,"v7",7,seq(13))

# Structural integrity: mismatched Keys/image, unsupported operation, and malformed MODIFY.
key_bad=rec_upsert(entity,"v8-key-bad",8,False,seq(14),name="MODIFY",old=("v7",7,False),key_id=entity+"-other")
old_id_bad=rec_upsert(entity,"v8-old-bad",8,False,seq(15),name="MODIFY",old=("v7",7,False,entity+"-old"))
missing_old=rec_upsert(entity,"v8-missing-old",8,False,seq(16),name="MODIFY",old=None)
unsupported=rec_upsert(entity,"v8-unsupported",8,False,seq(17),name="UPSERT",old=None)
r7=invoke([key_bad,old_id_bad,missing_old,unsupported])
expect_failures(r7,seq(14),seq(15),seq(16),seq(17))
canonical_live(get_item(entity),entity,"v7",7,seq(13))

# A failed record without a usable sequence number cannot be represented as a partial failure.
no_seq=rec_upsert(entity,"v8-no-seq",8,True,seq(18),name="MODIFY",old=("v7",7,False))
del no_seq["dynamodb"]["SequenceNumber"]
invoke_expect_error([no_seq])
canonical_live(get_item(entity),entity,"v7",7,seq(13))

# Numeric revisions and same-revision delete precedence in one successful chain.
newid=f"grader-{tag}-multi"
delete_item(newid)
chain=[
    rec_upsert(newid,"m9",9,False,seq(20),name="INSERT"),
    rec_upsert(newid,"m10",10,False,seq(21),name="MODIFY",old=("m9",9,False)),
    rec_remove(newid,"m10",10,seq(22)),
    # live order (10,0) is stale below tombstone order (10,1)
    rec_upsert(newid,"m10",10,False,seq(21),name="MODIFY",old=("m9",9,False)),
    rec_upsert(newid,"m11",11,False,seq(23),name="INSERT"),
]
r8=invoke(chain); expect_failures(r8)
canonical_live(get_item(newid),newid,"m11",11,seq(23))

# Projection/receipt atomicity and legacy partial-pair reconciliation.
partial_state=f"grader-{tag}-partial-state"
delete_item(partial_state)
state_seq=seq(50)
aws(["dynamodb","put-item","--table-name",S["processed_table"],"--item",json.dumps({
    "event_id":{"S":partial_state},"status":{"S":"processed"},"payload":{"S":"state-only"},
    "revision":{"N":"5"},"sequence_number":{"S":state_seq}})])
ps=invoke([rec_upsert(partial_state,"state-only",5,False,state_seq,name="INSERT")]); expect_failures(ps)
canonical_live(get_item(partial_state),partial_state,"state-only",5,state_seq)
expect_receipt(partial_state,"live",5,state_seq,"state-only")

partial_receipt=f"grader-{tag}-partial-receipt"
delete_item(partial_receipt)
receipt_seq=seq(51)
put_receipt_raw(expected_receipt(partial_receipt,"live",6,receipt_seq,"receipt-only"))
pr=invoke([rec_upsert(partial_receipt,"receipt-only",6,False,receipt_seq,name="INSERT")]); expect_failures(pr)
canonical_live(get_item(partial_receipt),partial_receipt,"receipt-only",6,receipt_seq)
expect_receipt(partial_receipt,"live",6,receipt_seq,"receipt-only")

blocked=f"grader-{tag}-receipt-conflict"
delete_item(blocked)
blocked_seq=seq(52)
bad_receipt=expected_receipt(blocked,"live",7,blocked_seq,"WRONG")
put_receipt_raw(bad_receipt)
br=invoke([rec_upsert(blocked,"right",7,False,blocked_seq,name="INSERT")]); expect_failures(br,blocked_seq)
if get_item(blocked) is not None:
    fail("projection advanced even though immutable receipt key was already conflicting; state/receipt were not atomic")
if get_receipt(blocked,"live",7,blocked_seq) != bad_receipt:
    fail("conflicting immutable receipt was overwritten")

def concurrent_calls(payloads):
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(payloads)) as ex:
        futs=[ex.submit(lambda_call,{"Records":p}) for p in payloads]
        results=[]
        for f in futs:
            try:
                meta,body=f.result(timeout=30)
            except Exception as exc:
                fail(f"concurrent Lambda invocation failed: {exc}")
            if meta.get("FunctionError"):
                fail(f"concurrent representable record raised whole invocation error: {body}")
            if not isinstance(body,dict) or not isinstance(body.get("batchItemFailures"),list):
                fail(f"invalid concurrent Lambda response: {body}")
            results.append(body)
        return results

race=f"grader-{tag}-race"
delete_item(race)
ra=rec_upsert(race,"A",20,False,seq(30),name="INSERT")
rb=rec_upsert(race,"B",20,False,seq(31),name="INSERT")
rr=concurrent_calls([[ra],[rb]])
all_failed=set().union(*(failure_ids(x) for x in rr))
if all_failed not in ({seq(30)},{seq(31)}):
    fail(f"equal-order concurrent conflict must choose exactly one winner and fail the other; got {sorted(all_failed)}")
winner_seq=seq(31) if seq(30) in all_failed else seq(30)
loser_seq=seq(30) if winner_seq==seq(31) else seq(31)
winner_payload="B" if winner_seq==seq(31) else "A"
canonical_live(get_item(race),race,winner_payload,20,winner_seq)
expect_receipt(race,"live",20,winner_seq,winner_payload)
expect_no_receipt(race,"live",20,loser_seq)

race2=f"grader-{tag}-race-delete"
delete_item(race2)
live21=rec_upsert(race2,"live21",21,False,seq(32),name="INSERT")
del21=rec_remove(race2,"live21",21,seq(33))
rr2=concurrent_calls([[live21],[del21]])
if any(failure_ids(x) for x in rr2):
    fail("same-revision live/REMOVE overlap should converge successfully with REMOVE winning")
canonical_deleted(get_item(race2),race2,21,seq(33))
expect_receipt(race2,"delete",21,seq(33))

race3=f"grader-{tag}-race-revision"
delete_item(race3)
low=rec_upsert(race3,"low",30,False,seq(34),name="INSERT")
high=rec_upsert(race3,"high",31,False,seq(35),name="INSERT")
rr3=concurrent_calls([[low],[high]])
if any(failure_ids(x) for x in rr3):
    fail("different-revision overlap should converge without a conflict")
canonical_live(get_item(race3),race3,"high",31,seq(35))
expect_receipt(race3,"live",31,seq(35),"high")


txid=f"tx-{tag}-ok"
txa=f"grader-{tag}-tx-a"; txb=f"grader-{tag}-tx-b"
for x in (txa,txb): delete_item(x)
txa_rec=rec_upsert(txa,"tx-a",40,False,seq(60),name="INSERT",tx=(txid,0,2))
txb_rec=rec_upsert(txb,"tx-b",41,False,seq(61),name="INSERT",tx=(txid,1,2))
tg=invoke([txa_rec,txb_rec]); expect_failures(tg)
canonical_live(get_item(txa),txa,"tx-a",40,seq(60))
canonical_live(get_item(txb),txb,"tx-b",41,seq(61))
expect_receipt(txa,"live",40,seq(60),"tx-a")
expect_receipt(txb,"live",41,seq(61),"tx-b")
# Full group replay is inert.
before_txa=get_item(txa); before_txb=get_item(txb)
tg2=invoke([txa_rec,txb_rec]); expect_failures(tg2)
if get_item(txa)!=before_txa or get_item(txb)!=before_txb:
    fail("successful transaction-envelope replay changed projection state")

# Poison in one member aborts the complete group: the good neighbour must not leak state/receipt.
txid2=f"tx-{tag}-poison"
txc=f"grader-{tag}-tx-c"; txd=f"grader-{tag}-tx-d"
for x in (txc,txd): delete_item(x)
good_member=rec_upsert(txc,"would-have-been-good",50,False,seq(62),name="INSERT",tx=(txid2,0,2))
bad_member=rec_upsert(txd,"poison",1,True,seq(63),name="INSERT",tx=(txid2,1,2))
tg3=invoke([good_member,bad_member]); expect_failures(tg3,seq(62),seq(63))
if get_item(txc) is not None or get_item(txd) is not None:
    fail("poisoned transaction envelope partially changed projection state")
expect_no_receipt(txc,"live",50,seq(62)); expect_no_receipt(txd,"live",1,seq(63))

# One immutable receipt conflict aborts the entire group before the other member can commit.
txid3=f"tx-{tag}-receipt"
txe=f"grader-{tag}-tx-e"; txf=f"grader-{tag}-tx-f"
for x in (txe,txf): delete_item(x)
seqe,seqf=seq(64),seq(65)
conflicting=expected_receipt(txf,"live",61,seqf,"WRONG")
put_receipt_raw(conflicting)
e_rec=rec_upsert(txe,"clean-neighbour",60,False,seqe,name="INSERT",tx=(txid3,0,2))
f_rec=rec_upsert(txf,"right",61,False,seqf,name="INSERT",tx=(txid3,1,2))
tg4=invoke([e_rec,f_rec]); expect_failures(tg4,seqe,seqf)
if get_item(txe) is not None or get_item(txf) is not None:
    fail("transaction group leaked projection state around an immutable receipt conflict")
expect_no_receipt(txe,"live",60,seqe)
if get_receipt(txf,"live",61,seqf) != conflicting:
    fail("transaction group overwrote its pre-existing conflicting receipt")

# Incomplete envelope is itself failed and must not be processed as a standalone record.
txid4=f"tx-{tag}-incomplete"
txg=f"grader-{tag}-tx-g"; delete_item(txg)
incomplete=rec_upsert(txg,"incomplete",70,False,seq(66),name="INSERT",tx=(txid4,0,2))
tg5=invoke([incomplete]); expect_failures(tg5,seq(66))
if get_item(txg) is not None:
    fail("incomplete transaction envelope was processed as a standalone mutation")
expect_no_receipt(txg,"live",70,seq(66))


# Recheck frozen state after behavioral grading.
source_scan=aws_json(["dynamodb","scan","--table-name",S["source_table"],"--consistent-read"])
source_items=sorted(source_scan.get("Items",[]), key=lambda x:json.dumps(x,sort_keys=True,separators=(",",":")))
if len(source_items) != S["source_item_count"] or h(source_items) != S["source_items_sha256"]:
    fail("source-table contents changed during repair/testing")
objects=[{k:o.get(k) for k in ["Key","ETag","Size","StorageClass"]} for o in aws_json(["s3api","list-objects-v2","--bucket",S["bucket"]]).get("Contents",[])]
objects.sort(key=lambda x:x["Key"])
if h(objects) != S["archive_objects_sha256"]:
    fail("failure-archive object set changed during repair/testing")
entry_hash,asset_hash=package_snapshot(S["function_name"])
if entry_hash != S["package_entries_sha256"] or asset_hash != S["package_assets_sha256"]:
    fail("compatibility deployment-package assets changed during repair")
compat_receipts=aws_json(["dynamodb","scan","--table-name",S["receipt_table"],"--consistent-read","--filter-expression","begins_with(event_id, :p)","--expression-attribute-values",json.dumps({":p":{"S":"compat-"}})]).get("Items",[])
compat_receipts=sorted(compat_receipts,key=lambda x:json.dumps(x,sort_keys=True,separators=(",",":")))
if h(compat_receipts) != S["receipt_compat_sha256"]:
    fail("frozen compat-* mutation receipt examples changed during repair/testing")

print("PASS: stream projection and immutable receipts are atomic, monotone, fail-closed, and compatibility-preserving")
