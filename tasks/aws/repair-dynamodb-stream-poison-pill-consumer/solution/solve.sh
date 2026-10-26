#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"

FUNCTION_NAME="$(python3 - <<'PY'
import json, subprocess, sys

def aws(*args):
    p=subprocess.run(["aws",*args,"--output","json"],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode:
        raise SystemExit(p.stderr.strip() or "AWS discovery failed")
    return json.loads(p.stdout or "{}")

funcs=aws("lambda","list-functions").get("Functions",[])
c=[]
for f in funcs:
    name=f.get("FunctionName","")
    arn=f.get("FunctionArn","")
    if not (name.startswith("jc-ddb-poison-") and name.endswith("-processor") and arn):
        continue
    tags=aws("lambda","list-tags","--resource",arn).get("Tags",{})
    if tags.get("CloudOpTask") != "ddb-stream-poison":
        continue
    c.append((f.get("LastModified", ""), name))
if not c:
    raise SystemExit("no tagged jc-ddb-poison processor found")
c.sort()
print(c[-1][1])
PY
)"

FUNCTION_JSON="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME")"
PROCESSED_TABLE="$(printf '%s' "$FUNCTION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Environment",{}).get("Variables",{}).get("PROCESSED_TABLE",""))')"
[ -n "$PROCESSED_TABLE" ] || { echo "processor has no PROCESSED_TABLE environment variable" >&2; exit 1; }

MAPS_JSON="$(aws lambda list-event-source-mappings --function-name "$FUNCTION_NAME")"
readarray -t MAP_INFO < <(printf '%s' "$MAPS_JSON" | python3 -c 'import json,sys; x=json.load(sys.stdin).get("EventSourceMappings",[]); x=[m for m in x if str(m.get("EventSourceArn","")).startswith("arn:") and ":dynamodb:" in str(m.get("EventSourceArn","")) and "/stream/" in str(m.get("EventSourceArn",""))]; assert len(x)==1, f"expected one DynamoDB mapping, found {len(x)}"; print(x[0]["UUID"]); print(x[0]["EventSourceArn"])')
ESM_UUID="${MAP_INFO[0]}"
STREAM_ARN="${MAP_INFO[1]}"

PREFIX="${FUNCTION_NAME%-processor}"
SUFFIX="${PREFIX##*-}"
BUCKET="$(python3 - "$SUFFIX" <<'PY'
import json, subprocess, sys
suffix=sys.argv[1]

def run(args, check=True):
    p=subprocess.run(["aws",*args],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if check and p.returncode:
        raise SystemExit(p.stderr.strip() or "AWS discovery failed")
    return p

buckets=json.loads(run(["s3api","list-buckets","--output","json"]).stdout or "{}").get("Buckets",[])
found=[]
for b in buckets:
    name=b.get("Name","")
    if not (name.startswith("jc-ddb-poison-archive-") and name.endswith("-"+suffix)):
        continue
    p=run(["s3api","get-bucket-tagging","--bucket",name,"--output","json"],check=False)
    if p.returncode:
        continue
    tags={t.get("Key"):t.get("Value") for t in json.loads(p.stdout or "{}").get("TagSet",[])}
    if tags.get("CloudOpTask")=="ddb-stream-poison":
        found.append(name)
if len(found)!=1:
    raise SystemExit(f"expected one tagged failure archive for suffix {suffix}, found {len(found)}")
print(found[0])
PY
)"
BUCKET_ARN="arn:aws:s3:::${BUCKET}"

cat >/tmp/lambda_function.py <<'PY'
import hashlib
import os
import boto3
from boto3.dynamodb.types import TypeSerializer
from botocore.exceptions import ClientError
from compat import handle as compat_handle

resource=boto3.resource("dynamodb")
projection=resource.Table(os.environ["PROCESSED_TABLE"])
receipts=resource.Table(os.environ["RECEIPT_TABLE"])
client=boto3.client("dynamodb")
ser=TypeSerializer()


class RecordFailure(Exception):
    def __init__(self, sequence_number, reason):
        super().__init__(reason)
        self.sequence_number=sequence_number


def _s(image,name):
    v=(image or {}).get(name)
    x=v.get("S") if isinstance(v,dict) else None
    return x if isinstance(x,str) and x else None


def _n(image,name):
    v=(image or {}).get(name)
    raw=v.get("N") if isinstance(v,dict) else None
    if raw is None: return None
    try:
        text=str(raw); n=int(text)
        if str(n)!=text and not (text.startswith("+") and str(n)==text[1:]): return None
        return n
    except Exception:
        return None


def _bool(image,name,default=False):
    v=(image or {}).get(name)
    if v is None: return default
    if not isinstance(v,dict) or not isinstance(v.get("BOOL"),bool): return None
    return v["BOOL"]


def _base(image):
    event_id=_s(image,"event_id"); payload=_s(image,"payload")
    revision=_n(image,"revision"); poison=_bool(image,"poison",False)
    if event_id is None or payload is None or revision is None or poison is None: return None
    return event_id,payload,revision,poison


def _receipt(event_id,kind,revision,seq,payload=None):
    prefix="L" if kind=="live" else "D"
    item={
        "event_id":event_id,
        "mutation_id":f"{prefix}#{revision}#{seq}",
        "kind":kind,
        "revision":revision,
        "sequence_number":seq,
    }
    if kind=="live": item["payload"]=payload
    return item


def _tx_from_image(image,seq):
    if not isinstance(image,dict): return None
    present=[name in image for name in ("tx_id","tx_index","tx_size")]
    if not any(present): return None
    if not all(present): raise RecordFailure(seq,"incomplete transaction metadata")
    tx_id=_s(image,"tx_id"); tx_index=_n(image,"tx_index"); tx_size=_n(image,"tx_size")
    if tx_id is None or tx_index is None or tx_size is None or tx_size < 1 or tx_index < 0 or tx_index >= tx_size:
        raise RecordFailure(seq,"invalid transaction metadata")
    return {"tx_id":tx_id,"tx_index":tx_index,"tx_size":tx_size}


def _peek_tx(record):
    ddb=record.get("dynamodb") if isinstance(record,dict) else None
    if not isinstance(ddb,dict): return None
    seq=ddb.get("SequenceNumber")
    if not isinstance(seq,str) or not seq: raise RuntimeError("failed record has no usable SequenceNumber")
    name=record.get("eventName")
    if name=="REMOVE":
        return _tx_from_image(ddb.get("OldImage"),seq)
    if name in ("INSERT","MODIFY"):
        return _tx_from_image(ddb.get("NewImage"),seq)
    # Unsupported operations may still identify their envelope through either image.
    return _tx_from_image(ddb.get("NewImage") or ddb.get("OldImage"),seq)


def _parse(record):
    ddb=record.get("dynamodb") if isinstance(record,dict) else None
    if not isinstance(ddb,dict): raise RuntimeError("unidentifiable stream record")
    seq=ddb.get("SequenceNumber")
    if not isinstance(seq,str) or not seq: raise RuntimeError("failed record has no usable SequenceNumber")
    key_id=_s(ddb.get("Keys"),"event_id")
    if key_id is None: raise RecordFailure(seq,"invalid key")
    name=record.get("eventName")
    if name in ("INSERT","MODIFY"):
        tx=_tx_from_image(ddb.get("NewImage"),seq)
        new=_base(ddb.get("NewImage"))
        if new is None: raise RecordFailure(seq,"malformed NewImage")
        event_id,payload,revision,poison=new
        if event_id!=key_id: raise RecordFailure(seq,"key/NewImage mismatch")
        if name=="MODIFY":
            old=_base(ddb.get("OldImage"))
            if old is None: raise RecordFailure(seq,"malformed OldImage")
            old_id,_,old_revision,_=old
            if old_id!=event_id or old_id!=key_id or old_revision>=revision:
                raise RecordFailure(seq,"non-monotone MODIFY")
        desired={"event_id":event_id,"status":"processed","payload":payload,"revision":revision,"sequence_number":seq}
        return event_id,(revision,0),desired,_receipt(event_id,"live",revision,seq,payload),seq,poison,tx
    if name=="REMOVE":
        tx=_tx_from_image(ddb.get("OldImage"),seq)
        old=_base(ddb.get("OldImage"))
        if old is None: raise RecordFailure(seq,"malformed OldImage")
        event_id,payload,revision,poison=old
        if event_id!=key_id: raise RecordFailure(seq,"key/OldImage mismatch")
        desired={"event_id":event_id,"status":"deleted","revision":revision,"sequence_number":seq}
        return event_id,(revision,1),desired,_receipt(event_id,"delete",revision,seq),seq,poison,tx
    raise RecordFailure(seq,"unsupported operation")


def _order(item):
    if not item: return None
    try: rev=int(item["revision"]); status=item["status"]
    except Exception: return None
    if status=="processed": return (rev,0)
    if status=="deleted": return (rev,1)
    return None


def _receipt_key(r): return {"event_id":r["event_id"],"mutation_id":r["mutation_id"]}

def _get_receipt(r): return receipts.get_item(Key=_receipt_key(r),ConsistentRead=True).get("Item")

def _av_map(d): return {k:ser.serialize(v) for k,v in d.items()}

def _token(event_id,mutation_id): return hashlib.sha256((event_id+"|"+mutation_id).encode()).hexdigest()[:32]


def _projection_condition(order,desired):
    revision,rank=order
    if rank==0:
        cond=("attribute_not_exists(event_id) OR #r < :r OR "
              "(#r = :r AND #s = :started AND #q = :seq AND #p = :payload) OR "
              "(#r = :r AND #s = :processed AND #q = :seq AND #p = :payload)")
        names={"#r":"revision","#s":"status","#q":"sequence_number","#p":"payload"}
        vals={":r":revision,":started":"started",":processed":"processed",":seq":desired["sequence_number"],":payload":desired["payload"]}
    else:
        cond=("attribute_not_exists(event_id) OR #r < :r OR "
              "(#r = :r AND #s = :processed) OR "
              "(#r = :r AND #s = :deleted AND #q = :seq)")
        names={"#r":"revision","#s":"status","#q":"sequence_number"}
        vals={":r":revision,":processed":"processed",":deleted":"deleted",":seq":desired["sequence_number"]}
    return cond,names,_av_map(vals)


def _transact_pair(event_id,order,desired,receipt,receipt_mode):
    cond,names,vals=_projection_condition(order,desired)
    tx=[{"Put":{"TableName":projection.name,"Item":_av_map(desired),"ConditionExpression":cond,
                "ExpressionAttributeNames":names,"ExpressionAttributeValues":vals}}]
    if receipt_mode=="create":
        tx.append({"Put":{"TableName":receipts.name,"Item":_av_map(receipt),
                          "ConditionExpression":"attribute_not_exists(event_id) AND attribute_not_exists(mutation_id)"}})
    elif receipt_mode=="check":
        tx.append({"ConditionCheck":{"TableName":receipts.name,"Key":_av_map(_receipt_key(receipt)),
                                     "ConditionExpression":"#k = :k AND #r = :r AND #q = :q" + (" AND #p = :p" if receipt["kind"]=="live" else ""),
                                     "ExpressionAttributeNames":{"#k":"kind","#r":"revision","#q":"sequence_number",**({"#p":"payload"} if receipt["kind"]=="live" else {})},
                                     "ExpressionAttributeValues":_av_map({":k":receipt["kind"],":r":receipt["revision"],":q":receipt["sequence_number"],**({":p":receipt["payload"]} if receipt["kind"]=="live" else {})})}})
    client.transact_write_items(TransactItems=tx)


def _apply(event_id,order,desired,receipt,seq):
    for _ in range(6):
        current=projection.get_item(Key={"event_id":event_id},ConsistentRead=True).get("Item")
        got_receipt=_get_receipt(receipt)
        current_order=_order(current)

        if current is not None and current_order is None and current.get("status")!="started":
            raise RecordFailure(seq,"non-canonical projection")
        if current_order is not None and current_order>order:
            return
        if current_order==order and current!=desired:
            raise RecordFailure(seq,"equal-order conflict")
        if got_receipt is not None and got_receipt!=receipt:
            raise RecordFailure(seq,"conflicting immutable receipt")
        if current==desired and got_receipt==receipt:
            return

        # Complete either side of a legacy partial pair atomically with the other side fixed.
        mode="check" if got_receipt==receipt else "create"
        try:
            _transact_pair(event_id,order,desired,receipt,mode)
            return
        except ClientError as exc:
            if exc.response.get("Error",{}).get("Code") not in ("TransactionCanceledException","ConditionalCheckFailedException"):
                raise
            continue
    raise RecordFailure(seq,"could not establish atomic projection/receipt pair")



def _receipt_check_action(receipt):
    vals={":k":receipt["kind"],":r":receipt["revision"],":q":receipt["sequence_number"]}
    names={"#k":"kind","#r":"revision","#q":"sequence_number"}
    expr="#k = :k AND #r = :r AND #q = :q"
    if receipt["kind"]=="live":
        expr+=" AND #p = :p"; names["#p"]="payload"; vals[":p"]=receipt["payload"]
    return {"ConditionCheck":{"TableName":receipts.name,"Key":_av_map(_receipt_key(receipt)),
                              "ConditionExpression":expr,"ExpressionAttributeNames":names,
                              "ExpressionAttributeValues":_av_map(vals)}}


def _apply_group(members):
    # Members are distinct logical entities. Re-read and retry the entire transaction when
    # another invocation moves any member between decision and commit.
    for _ in range(8):
        tx=[]
        for event_id,order,desired,receipt,seq,poison,txmeta in members:
            if poison:
                return False
            current=projection.get_item(Key={"event_id":event_id},ConsistentRead=True).get("Item")
            got_receipt=_get_receipt(receipt)
            current_order=_order(current)

            if current is not None and current_order is None and current.get("status")!="started":
                return False
            if current_order is not None and current_order>order:
                continue
            if current_order==order and current!=desired:
                return False
            if got_receipt is not None and got_receipt!=receipt:
                return False
            if current==desired and got_receipt==receipt:
                continue

            cond,names,vals=_projection_condition(order,desired)
            tx.append({"Put":{"TableName":projection.name,"Item":_av_map(desired),
                              "ConditionExpression":cond,"ExpressionAttributeNames":names,
                              "ExpressionAttributeValues":vals}})
            if got_receipt==receipt:
                tx.append(_receipt_check_action(receipt))
            else:
                tx.append({"Put":{"TableName":receipts.name,"Item":_av_map(receipt),
                                  "ConditionExpression":"attribute_not_exists(event_id) AND attribute_not_exists(mutation_id)"}})
        if not tx:
            return True
        try:
            client.transact_write_items(TransactItems=tx)
            return True
        except ClientError as exc:
            if exc.response.get("Error",{}).get("Code")!="TransactionCanceledException":
                raise
            continue
    return False


def _clear_started(event_id,desired,seq):
    try:
        projection.delete_item(
            Key={"event_id":event_id},
            ConditionExpression="#s=:s AND #r=:r AND #q=:q AND #p=:p",
            ExpressionAttributeNames={"#s":"status","#r":"revision","#q":"sequence_number","#p":"payload"},
            ExpressionAttributeValues={":s":"started",":r":desired["revision"],":q":seq,":p":desired.get("payload")},
        )
    except ClientError as exc:
        if exc.response.get("Error",{}).get("Code")!="ConditionalCheckFailedException": raise


def handler(event,context):
    if isinstance(event,dict) and event.get("contract")=="compat-v1": return compat_handle(event)
    records=event.get("Records",[]) if isinstance(event,dict) else []
    failures=[]
    groups={}
    standalone=[]

    # Discover transaction envelopes before mutating anything so a later bad member cannot
    # leave earlier members committed.
    for i,record in enumerate(records):
        try:
            tx=_peek_tx(record)
        except RecordFailure as exc:
            failures.append({"itemIdentifier":exc.sequence_number})
            continue
        if tx is None:
            standalone.append(i)
        else:
            groups.setdefault(tx["tx_id"],[]).append((i,tx))

    for tx_id,entries in groups.items():
        seqs=[]
        for i,_ in entries:
            ddb=records[i].get("dynamodb") if isinstance(records[i],dict) else None
            seq=(ddb or {}).get("SequenceNumber")
            if not isinstance(seq,str) or not seq:
                raise RuntimeError("transaction member has no usable SequenceNumber")
            seqs.append(seq)
        sizes={m["tx_size"] for _,m in entries}
        indices=[m["tx_index"] for _,m in entries]
        if len(sizes)!=1 or len(entries)!=next(iter(sizes)) or sorted(indices)!=list(range(next(iter(sizes)))):
            failures.extend({"itemIdentifier":s} for s in seqs)
            continue
        try:
            members=[_parse(records[i]) for i,_ in sorted(entries,key=lambda z:z[1]["tx_index"])]
        except RecordFailure:
            failures.extend({"itemIdentifier":s} for s in seqs)
            continue
        if any(m[6] is None or m[6]["tx_id"]!=tx_id for m in members):
            failures.extend({"itemIdentifier":s} for s in seqs)
            continue
        if len({m[0] for m in members}) != len(members):
            failures.extend({"itemIdentifier":s} for s in seqs)
            continue
        if not _apply_group(members):
            failures.extend({"itemIdentifier":s} for s in seqs)

    for i in standalone:
        try:
            event_id,order,desired,receipt,seq,poison,_=_parse(records[i])
            if poison:
                if desired.get("status")=="processed": _clear_started(event_id,desired,seq)
                raise RecordFailure(seq,"poison record")
            _apply(event_id,order,desired,receipt,seq)
        except RecordFailure as exc:
            failures.append({"itemIdentifier":exc.sequence_number})
    # Preserve one identifier per failed stream record.
    seen=set(); out=[]
    for x in failures:
        if x["itemIdentifier"] not in seen:
            seen.add(x["itemIdentifier"]); out.append(x)
    return {"batchItemFailures":out}

PY
CODE_URL="$(aws lambda get-function --function-name "$FUNCTION_NAME" --query 'Code.Location' --output text)"
python3 - "$CODE_URL" <<'PY'
import io,sys,urllib.request,zipfile
url=sys.argv[1]
with urllib.request.urlopen(url, timeout=30) as r:
    old_bytes=r.read()
with zipfile.ZipFile(io.BytesIO(old_bytes),"r") as old, zipfile.ZipFile("/tmp/ddb-poison-function.zip","w",zipfile.ZIP_DEFLATED) as new:
    for info in old.infolist():
        if info.is_dir() or info.filename == "lambda_function.py":
            continue
        new.writestr(info.filename, old.read(info.filename))
    new.write("/tmp/lambda_function.py","lambda_function.py")
PY
aws lambda update-function-code --function-name "$FUNCTION_NAME" --zip-file fileb:///tmp/ddb-poison-function.zip >/dev/null
aws lambda wait function-updated-v2 --function-name "$FUNCTION_NAME"

aws lambda update-event-source-mapping \
  --uuid "$ESM_UUID" \
  --function-response-types ReportBatchItemFailures \
  --bisect-batch-on-function-error \
  --maximum-retry-attempts 2 \
  --maximum-record-age-in-seconds 3600 \
  --destination-config "{\"OnFailure\":{\"Destination\":\"${BUCKET_ARN}\"}}" >/dev/null

for i in $(seq 1 30); do
  J="$(aws lambda get-event-source-mapping --uuid "$ESM_UUID")"
  OK="$(printf '%s' "$J" | python3 -c 'import json,sys; x=json.load(sys.stdin); print("yes" if x.get("State")=="Enabled" and x.get("BisectBatchOnFunctionError") is True and x.get("MaximumRetryAttempts")==2 and x.get("MaximumRecordAgeInSeconds")==3600 and "ReportBatchItemFailures" in x.get("FunctionResponseTypes",[]) else "no")')"
  [ "$OK" = yes ] && break
  [ "$i" -eq 30 ] && { echo "event source mapping update did not settle" >&2; exit 1; }
  sleep 1
done
rm -f /tmp/lambda_function.py /tmp/ddb-poison-function.zip
