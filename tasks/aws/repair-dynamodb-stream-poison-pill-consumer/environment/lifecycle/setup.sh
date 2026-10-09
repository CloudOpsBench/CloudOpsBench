#!/usr/bin/env bash
# Creates a DynamoDB source table with a stream, processed and receipt tables, a
# failure-archive bucket and a Lambda stream consumer whose handler mishandles
# poison and REMOVE records. Records resource identifiers and hashes of the
# protected configuration in seed_state.json.
set -euo pipefail
export AWS_PAGER=""

REGION="${AWS_REGION:-us-east-1}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
SUFFIX="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(3))
PY
)"
PREFIX="jc-ddb-poison-${SUFFIX}"
SOURCE_TABLE="${PREFIX}-source"
PROCESSED_TABLE="${PREFIX}-processed"
RECEIPT_TABLE="${PREFIX}-receipts"
FUNCTION_NAME="${PREFIX}-processor"
ROLE_NAME="${PREFIX}-lambda-role"
POLICY_NAME="${PREFIX}-lambda-access"
BUCKET="jc-ddb-poison-archive-${ACCT}-${SUFFIX}"

cat > cleanup_state.json <<JSON
{"function_name":"${FUNCTION_NAME}","role_name":"${ROLE_NAME}","role_policy_name":"${POLICY_NAME}","source_table":"${SOURCE_TABLE}","processed_table":"${PROCESSED_TABLE}","receipt_table":"${RECEIPT_TABLE}","bucket":"${BUCKET}","event_source_mapping_uuid":""}
JSON

cat >/tmp/ddb-poison-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file:///tmp/ddb-poison-trust.json >/dev/null
ROLE_ARN="arn:aws:iam::${ACCT}:role/${ROLE_NAME}"

aws dynamodb create-table \
  --table-name "$SOURCE_TABLE" \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --tags Key=CloudOpTask,Value=ddb-stream-poison >/dev/null

aws dynamodb create-table \
  --table-name "$PROCESSED_TABLE" \
  --attribute-definitions AttributeName=event_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=CloudOpTask,Value=ddb-stream-poison >/dev/null

aws dynamodb create-table \
  --table-name "$RECEIPT_TABLE" \
  --attribute-definitions AttributeName=event_id,AttributeType=S AttributeName=mutation_id,AttributeType=S \
  --key-schema AttributeName=event_id,KeyType=HASH AttributeName=mutation_id,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=CloudOpTask,Value=ddb-stream-poison >/dev/null

aws dynamodb wait table-exists --table-name "$SOURCE_TABLE"
aws dynamodb wait table-exists --table-name "$PROCESSED_TABLE"
aws dynamodb wait table-exists --table-name "$RECEIPT_TABLE"

aws dynamodb put-item --table-name "$RECEIPT_TABLE" --item '{"event_id":{"S":"compat-receipt-live"},"mutation_id":{"S":"L#7#70000000000000000001"},"kind":{"S":"live"},"revision":{"N":"7"},"sequence_number":{"S":"70000000000000000001"},"payload":{"S":"baseline"}}'
aws dynamodb put-item --table-name "$RECEIPT_TABLE" --item '{"event_id":{"S":"compat-receipt-delete"},"mutation_id":{"S":"D#4#70000000000000000002"},"kind":{"S":"delete"},"revision":{"N":"4"},"sequence_number":{"S":"70000000000000000002"}}'
SOURCE_JSON="$(aws dynamodb describe-table --table-name "$SOURCE_TABLE")"
PROCESSED_JSON="$(aws dynamodb describe-table --table-name "$PROCESSED_TABLE")"
RECEIPT_JSON="$(aws dynamodb describe-table --table-name "$RECEIPT_TABLE")"
SOURCE_ARN="$(printf '%s' "$SOURCE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Table"]["TableArn"])')"
SOURCE_ID="$(printf '%s' "$SOURCE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Table"]["TableId"])')"
STREAM_ARN="$(printf '%s' "$SOURCE_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Table"]["LatestStreamArn"])')"
PROCESSED_ARN="$(printf '%s' "$PROCESSED_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Table"]["TableArn"])')"
PROCESSED_ID="$(printf '%s' "$PROCESSED_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Table"]["TableId"])')"
RECEIPT_ARN="$(printf '%s' "$RECEIPT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Table"]["TableArn"])')"
RECEIPT_ID="$(printf '%s' "$RECEIPT_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Table"]["TableId"])')"

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
fi
aws s3api put-bucket-tagging --bucket "$BUCKET" --tagging 'TagSet=[{Key=CloudOpTask,Value=ddb-stream-poison}]'
BUCKET_ARN="arn:aws:s3:::${BUCKET}"

cat >/tmp/ddb-poison-role-policy.json <<JSON
{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"},
    {"Effect":"Allow","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:DeleteItem","dynamodb:ConditionCheckItem"],"Resource":["${PROCESSED_ARN}","${RECEIPT_ARN}"]},
    {"Effect":"Allow","Action":"dynamodb:TransactWriteItems","Resource":["${PROCESSED_ARN}","${RECEIPT_ARN}"]},
    {"Effect":"Allow","Action":["dynamodb:DescribeStream","dynamodb:GetRecords","dynamodb:GetShardIterator"],"Resource":"${STREAM_ARN}"},
    {"Effect":"Allow","Action":"dynamodb:ListStreams","Resource":"*"},
    {"Effect":"Allow","Action":"s3:ListBucket","Resource":"${BUCKET_ARN}"},
    {"Effect":"Allow","Action":"s3:PutObject","Resource":"${BUCKET_ARN}/*"}
  ]
}
JSON
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" --policy-document file:///tmp/ddb-poison-role-policy.json

cat >/tmp/compat.py <<'PY'
import hashlib
import json
import os

_SCHEMA_PATH = os.path.join(os.path.dirname(__file__), "compat_schema.json")
with open(_SCHEMA_PATH, "r", encoding="utf-8") as _f:
    _SCHEMA = json.load(_f)


def handle(event):
    request_id = event["request_id"]
    values = event.get("values", [])
    canonical = json.dumps(values, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256((_SCHEMA["prefix"] + "|" + canonical).encode()).hexdigest()
    return {
        "contract": "compat-v1",
        "request_id": request_id,
        "count": len(values),
        "digest": digest,
    }
PY

cat >/tmp/compat_schema.json <<'JSON'
{"contract":"compat-v1","prefix":"jc-ddb-compat-2026","version":1}
JSON

cat >/tmp/lambda_function.py <<'PY'
import os
import boto3
from botocore.exceptions import ClientError
from compat import handle as compat_handle

table = boto3.resource("dynamodb").Table(os.environ["PROCESSED_TABLE"])


def _decode(record):
    # BROKEN stream path: assumes every record has NewImage and event_id alone identifies replay.
    image = record["dynamodb"]["NewImage"]
    return (
        image["event_id"]["S"],
        image["payload"]["S"],
        int(image["revision"]["N"]),
        bool(image.get("poison", {}).get("BOOL", False)),
        record["dynamodb"]["SequenceNumber"],
    )


def handler(event, context):
    # Healthy compatibility path. This and its package assets are frozen.
    if isinstance(event, dict) and event.get("contract") == "compat-v1":
        return compat_handle(event)

    # BROKEN stream path: event_id is treated as the idempotency key; REMOVE cannot be decoded;
    # poison leaves a started marker; equal-revision delete/live ordering is not represented.
    for record in event.get("Records", []):
        event_id, payload, revision, poison, sequence_number = _decode(record)
        try:
            table.put_item(
                Item={
                    "event_id": event_id,
                    "status": "started",
                    "payload": payload,
                    "revision": revision,
                    "sequence_number": sequence_number,
                },
                ConditionExpression="attribute_not_exists(event_id)",
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                continue
            raise
        if poison:
            raise RuntimeError("poison record")
        table.put_item(Item={
            "event_id": event_id,
            "status": "processed",
            "payload": payload,
            "revision": revision,
            "sequence_number": sequence_number,
        })
    return {"batchItemFailures": []}
PY
python3 - <<'PY'
import zipfile
with zipfile.ZipFile('/tmp/ddb-poison-function.zip','w',zipfile.ZIP_DEFLATED) as z:
    for path,name in [
        ('/tmp/lambda_function.py','lambda_function.py'),
        ('/tmp/compat.py','compat.py'),
        ('/tmp/compat_schema.json','compat_schema.json'),
    ]:
        z.write(path,name)
PY

# Retry while the new IAM role propagates.
for i in $(seq 1 20); do
  if aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime python3.12 \
      --role "$ROLE_ARN" \
      --handler lambda_function.handler \
      --zip-file fileb:///tmp/ddb-poison-function.zip \
      --timeout 10 \
      --memory-size 128 \
      --environment "Variables={PROCESSED_TABLE=${PROCESSED_TABLE},RECEIPT_TABLE=${RECEIPT_TABLE}}" \
      --tags CloudOpTask=ddb-stream-poison >/tmp/ddb-poison-create-function.json 2>/tmp/ddb-poison-create-function.err; then
    break
  fi
  if [ "$i" -eq 20 ]; then cat /tmp/ddb-poison-create-function.err >&2; exit 1; fi
  sleep 1
 done
aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME"
aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"
FUNCTION_JSON="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME")"
FUNCTION_ARN="$(printf '%s' "$FUNCTION_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["FunctionArn"])')"

FROZEN_VERSION_JSON="$(aws lambda publish-version --function-name "$FUNCTION_NAME" --description "frozen compatibility snapshot")"
FROZEN_VERSION="$(printf '%s' "$FROZEN_VERSION_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["Version"])')"
aws lambda create-alias --function-name "$FUNCTION_NAME" --name COMPAT --function-version "$FROZEN_VERSION" --description "frozen compatibility alias" >/dev/null

ESM_JSON=""
for i in $(seq 1 20); do
  if ESM_JSON="$(aws lambda create-event-source-mapping \
      --event-source-arn "$STREAM_ARN" \
      --function-name "$FUNCTION_NAME" \
      --starting-position TRIM_HORIZON \
      --batch-size 5 \
      --parallelization-factor 1 \
      --maximum-retry-attempts -1 \
      --maximum-record-age-in-seconds -1 \
      --no-bisect-batch-on-function-error 2>/tmp/ddb-poison-create-esm.err)"; then
    break
  fi
  if [ "$i" -eq 20 ]; then cat /tmp/ddb-poison-create-esm.err >&2; exit 1; fi
  sleep 1
done
ESM_UUID="$(printf '%s' "$ESM_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["UUID"])')"
python3 - "$ESM_UUID" <<'PY'
import json,sys
p='cleanup_state.json'
x=json.load(open(p)); x['event_source_mapping_uuid']=sys.argv[1]
open(p,'w').write(json.dumps(x))
PY

for i in $(seq 1 30); do
  STATE="$(aws lambda get-event-source-mapping --uuid "$ESM_UUID" --query State --output text 2>/dev/null || true)"
  [ "$STATE" = "Enabled" ] && break
  [ "$i" -eq 30 ] && { echo "event source mapping did not become Enabled" >&2; exit 1; }
  sleep 1
 done

ROLE_POLICY_DOC="$(aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" --query PolicyDocument --output json)"
ROLE_POLICY_HASH="$(printf '%s' "$ROLE_POLICY_DOC" | python3 -c 'import json,sys,hashlib; x=json.load(sys.stdin); print(hashlib.sha256(json.dumps(x,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
ROLE_TRUST_DOC="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.AssumeRolePolicyDocument --output json)"
ROLE_TRUST_HASH="$(printf '%s' "$ROLE_TRUST_DOC" | python3 -c 'import json,sys,hashlib; x=json.load(sys.stdin); print(hashlib.sha256(json.dumps(x,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
ROLE_INLINE_NAMES_HASH="$(aws iam list-role-policies --role-name "$ROLE_NAME" --query PolicyNames --output json | python3 -c 'import json,sys,hashlib; x=sorted(json.load(sys.stdin)); print(hashlib.sha256(json.dumps(x,separators=(",",":")).encode()).hexdigest())')"
ROLE_ATTACHED_ARNS_HASH="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output json | python3 -c 'import json,sys,hashlib; x=sorted(json.load(sys.stdin)); print(hashlib.sha256(json.dumps(x,separators=(",",":")).encode()).hexdigest())')"
FUNCTION_CONFIG_HASH="$(printf '%s' "$FUNCTION_JSON" | python3 -c 'import json,sys,hashlib; x=json.load(sys.stdin); v=x.get("VpcConfig") or {}; p={"Role":x.get("Role"),"Runtime":x.get("Runtime"),"Handler":x.get("Handler"),"Description":x.get("Description",""),"Timeout":x.get("Timeout"),"MemorySize":x.get("MemorySize"),"Environment":(x.get("Environment") or {}).get("Variables",{}),"KMSKeyArn":x.get("KMSKeyArn",""),"TracingMode":(x.get("TracingConfig") or {}).get("Mode"),"Layers":[z.get("Arn") for z in x.get("Layers",[])],"DeadLetterConfig":x.get("DeadLetterConfig") or {},"FileSystemConfigs":x.get("FileSystemConfigs") or [],"PackageType":x.get("PackageType"),"Architectures":x.get("Architectures") or [],"EphemeralStorage":x.get("EphemeralStorage") or {},"SnapStartApplyOn":(x.get("SnapStart") or {}).get("ApplyOn"),"LoggingConfig":x.get("LoggingConfig") or {},"VpcConfig":{k:v.get(k) for k in ["VpcId","SubnetIds","SecurityGroupIds","Ipv6AllowedForDualStack"] if k in v}}; print(hashlib.sha256(json.dumps(p,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"

PACKAGE_ASSETS_HASH="$(python3 - <<'PY'
import hashlib,json
assets={}
for name,path in [("compat.py","/tmp/compat.py"),("compat_schema.json","/tmp/compat_schema.json")]:
    assets[name]=hashlib.sha256(open(path,"rb").read()).hexdigest()
print(hashlib.sha256(json.dumps(assets,sort_keys=True,separators=(",",":")).encode()).hexdigest())
PY
)"
PACKAGE_ENTRIES_HASH="$(python3 - <<'PY'
import hashlib,json,zipfile
with zipfile.ZipFile('/tmp/ddb-poison-function.zip') as z:
    names=sorted(x for x in z.namelist() if not x.endswith('/'))
print(hashlib.sha256(json.dumps(names,separators=(",",":")).encode()).hexdigest())
PY
)"

ROLE_JSON="$(aws iam get-role --role-name "$ROLE_NAME")"
ROLE_ID="$(printf '%s' "$ROLE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Role"]["RoleId"])')"
ROLE_STATE_HASH="$(printf '%s' "$ROLE_JSON" | python3 -c 'import json,sys,hashlib; r=json.load(sys.stdin)["Role"]; p={k:r.get(k) for k in ["Arn","Path","MaxSessionDuration","PermissionsBoundary","Tags"]}; print(hashlib.sha256(json.dumps(p,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
FUNCTION_CONCURRENCY_JSON="$(aws lambda get-function-concurrency --function-name "$FUNCTION_NAME" --output json)"
[ -n "$FUNCTION_CONCURRENCY_JSON" ] || FUNCTION_CONCURRENCY_JSON='{}'
FUNCTION_CONCURRENCY_HASH="$(printf '%s' "$FUNCTION_CONCURRENCY_JSON" | python3 -c 'import json,sys,hashlib; x=json.load(sys.stdin); print(hashlib.sha256(json.dumps(x,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
FUNCTION_TAGS_HASH="$(aws lambda list-tags --resource "$FUNCTION_ARN" --query Tags --output json | python3 -c 'import json,sys,hashlib; x=json.load(sys.stdin); print(hashlib.sha256(json.dumps(x,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
ESM_SEED_JSON="$(aws lambda get-event-source-mapping --uuid "$ESM_UUID")"
FILTER_HASH="$(printf '%s' "$ESM_SEED_JSON" | python3 -c 'import json,sys,hashlib; x=json.load(sys.stdin).get("FilterCriteria") or {}; print(hashlib.sha256(json.dumps(x,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
ESM_STATIC_HASH="$(printf '%s' "$ESM_SEED_JSON" | python3 -c 'import json,sys,hashlib; x=json.load(sys.stdin); drop={"UUID","LastModified","LastProcessingResult","State","StateTransitionReason","DestinationConfig","MaximumRecordAgeInSeconds","BisectBatchOnFunctionError","MaximumRetryAttempts","FunctionResponseTypes"}; p={k:v for k,v in x.items() if k not in drop}; print(hashlib.sha256(json.dumps(p,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
MAX_BATCH_WINDOW="$(printf '%s' "$ESM_SEED_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("MaximumBatchingWindowInSeconds",0))')"
TUMBLING_WINDOW="$(printf '%s' "$ESM_SEED_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("TumblingWindowInSeconds",0))')"
PUBLISHED_VERSIONS_HASH="$(aws lambda list-versions-by-function --function-name "$FUNCTION_NAME" --output json | python3 -c 'import json,sys,hashlib; vs=[]; [vs.append({k:v.get(k) for k in ["Version","FunctionArn","CodeSha256","Description"]}) for v in json.load(sys.stdin).get("Versions",[]) if v.get("Version") != "$LATEST"]; vs.sort(key=lambda x:int(x["Version"])); print(hashlib.sha256(json.dumps(vs,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
ALIASES_HASH="$(aws lambda list-aliases --function-name "$FUNCTION_NAME" --output json | python3 -c 'import json,sys,hashlib; xs=[{k:a.get(k) for k in ["Name","AliasArn","FunctionVersion","Description","RoutingConfig"]} for a in json.load(sys.stdin).get("Aliases",[])]; xs.sort(key=lambda x:x["Name"]); print(hashlib.sha256(json.dumps(xs,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
SOURCE_ITEMS_HASH="$(aws dynamodb scan --table-name "$SOURCE_TABLE" --consistent-read --output json | python3 -c 'import json,sys,hashlib; xs=json.load(sys.stdin).get("Items",[]); xs=sorted(xs,key=lambda x:json.dumps(x,sort_keys=True,separators=(",",":"))); print(hashlib.sha256(json.dumps(xs,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
SOURCE_ITEM_COUNT="$(aws dynamodb scan --table-name "$SOURCE_TABLE" --consistent-read --select COUNT --query Count --output text)"
ARCHIVE_OBJECTS_HASH="$(aws s3api list-objects-v2 --bucket "$BUCKET" --output json | python3 -c 'import json,sys,hashlib; xs=[{k:o.get(k) for k in ["Key","ETag","Size","StorageClass"]} for o in json.load(sys.stdin).get("Contents",[])]; xs.sort(key=lambda x:x["Key"]); print(hashlib.sha256(json.dumps(xs,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"
RECEIPT_COMPAT_HASH="$(aws dynamodb scan --table-name "$RECEIPT_TABLE" --consistent-read --filter-expression 'begins_with(event_id, :p)' --expression-attribute-values '{":p":{"S":"compat-"}}' --output json | python3 -c 'import json,sys,hashlib; xs=json.load(sys.stdin).get("Items",[]); xs=sorted(xs,key=lambda x:json.dumps(x,sort_keys=True,separators=(",",":"))); print(hashlib.sha256(json.dumps(xs,sort_keys=True,separators=(",",":")).encode()).hexdigest())')"

cat > seed_state.json <<JSON
{
  "region":"${REGION}",
  "account":"${ACCT}",
  "prefix":"${PREFIX}",
  "source_table":"${SOURCE_TABLE}",
  "source_table_arn":"${SOURCE_ARN}",
  "source_table_id":"${SOURCE_ID}",
  "stream_arn":"${STREAM_ARN}",
  "stream_view_type":"NEW_AND_OLD_IMAGES",
  "processed_table":"${PROCESSED_TABLE}",
  "processed_table_arn":"${PROCESSED_ARN}",
  "processed_table_id":"${PROCESSED_ID}",
  "receipt_table":"${RECEIPT_TABLE}",
  "receipt_table_arn":"${RECEIPT_ARN}",
  "receipt_table_id":"${RECEIPT_ID}",
  "receipt_compat_sha256":"${RECEIPT_COMPAT_HASH}",
  "function_name":"${FUNCTION_NAME}",
  "function_arn":"${FUNCTION_ARN}",
  "function_role":"${ROLE_ARN}",
  "function_config_sha256":"${FUNCTION_CONFIG_HASH}",
  "function_concurrency_sha256":"${FUNCTION_CONCURRENCY_HASH}",
  "function_tags_sha256":"${FUNCTION_TAGS_HASH}",
  "published_versions_sha256":"${PUBLISHED_VERSIONS_HASH}",
  "aliases_sha256":"${ALIASES_HASH}",
  "package_assets_sha256":"${PACKAGE_ASSETS_HASH}",
  "package_entries_sha256":"${PACKAGE_ENTRIES_HASH}",
  "frozen_compat_version":"${FROZEN_VERSION}",
  "source_items_sha256":"${SOURCE_ITEMS_HASH}",
  "source_item_count":${SOURCE_ITEM_COUNT},
  "archive_objects_sha256":"${ARCHIVE_OBJECTS_HASH}",
  "role_name":"${ROLE_NAME}",
  "role_id":"${ROLE_ID}",
  "role_state_sha256":"${ROLE_STATE_HASH}",
  "role_policy_name":"${POLICY_NAME}",
  "role_policy_sha256":"${ROLE_POLICY_HASH}",
  "role_trust_sha256":"${ROLE_TRUST_HASH}",
  "role_inline_names_sha256":"${ROLE_INLINE_NAMES_HASH}",
  "role_attached_arns_sha256":"${ROLE_ATTACHED_ARNS_HASH}",
  "event_source_mapping_uuid":"${ESM_UUID}",
  "bucket":"${BUCKET}",
  "bucket_arn":"${BUCKET_ARN}",
  "batch_size":5,
  "parallelization_factor":1,
  "starting_position":"TRIM_HORIZON",
  "maximum_batching_window":${MAX_BATCH_WINDOW},
  "tumbling_window":${TUMBLING_WINDOW},
  "filter_criteria_sha256":"${FILTER_HASH}",
  "event_source_static_sha256":"${ESM_STATIC_HASH}"
}
JSON

rm -f /tmp/ddb-poison-*.json /tmp/ddb-poison-*.err /tmp/ddb-poison-function.zip /tmp/lambda_function.py /tmp/compat.py /tmp/compat_schema.json

echo "[setup] prefix=${PREFIX} region=${REGION} mapping=${ESM_UUID}"
