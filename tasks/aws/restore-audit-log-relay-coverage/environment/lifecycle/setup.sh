#!/usr/bin/env bash
set -euo pipefail
# Log group names start with "/"; keep Git Bash from rewriting them as Windows paths.
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
WEST="us-west-2"
ACCT="$(aws sts get-caller-identity --query Account --output text)"

# --- clean residue from an earlier run in this account -------------------------------------
for r in "$REGION" "$WEST"; do
  for p in $(aws logs describe-account-policies --policy-type SUBSCRIPTION_FILTER_POLICY \
               --region "$r" --query 'accountPolicies[].policyName' --output text 2>/dev/null); do
    aws logs delete-account-policy --policy-name "$p" --policy-type SUBSCRIPTION_FILTER_POLICY \
      --region "$r" >/dev/null 2>&1 || true
  done
  for g in $(aws logs describe-log-groups --log-group-name-prefix /svc/ --region "$r" \
               --query 'logGroups[].logGroupName' --output text 2>/dev/null); do
    aws logs delete-log-group --log-group-name "$g" --region "$r" >/dev/null 2>&1 || true
  done
  for s in $(aws kinesis list-streams --region "$r" --query 'StreamNames' --output text 2>/dev/null); do
    case "$s" in audit-relay-*) aws kinesis delete-stream --stream-name "$s" \
        --enforce-consumer-deletion --region "$r" >/dev/null 2>&1 || true ;; esac
  done
done
for r in $(aws iam list-roles --query 'Roles[?starts_with(RoleName,`audit-relay-cwl-`)].RoleName' --output text 2>/dev/null); do
  for pol in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$pol" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
done

SUF="$(python3 -c 'import secrets;print(secrets.token_hex(4))')"

STREAM="audit-relay-stream-${SUF}"
ARCHIVE="audit-relay-archive-${SUF}"
WSTREAM="audit-relay-stream-${SUF}"
ROLE="audit-relay-cwl-${SUF}"
G_CHECKOUT="/svc/checkout-api-${SUF}"
G_PAYMENTS="/svc/payments-api-${SUF}"
G_INVENTORY="/svc/inventory-worker-${SUF}"
G_PRICING="/svc/pricing-engine-${SUF}"
G_VENDOR="/svc/vendor-callback-raw-${SUF}"
G_EDGE="/svc/edge-cache-${SUF}"

# --- destination streams -------------------------------------------------------------------
aws kinesis create-stream --stream-name "$STREAM" --shard-count 1 --region "$REGION" >/dev/null
aws kinesis create-stream --stream-name "$ARCHIVE" --shard-count 1 --region "$REGION" >/dev/null
aws kinesis create-stream --stream-name "$WSTREAM" --shard-count 1 --region "$WEST" >/dev/null
aws kinesis wait stream-exists --stream-name "$STREAM" --region "$REGION"
aws kinesis wait stream-exists --stream-name "$ARCHIVE" --region "$REGION"
aws kinesis wait stream-exists --stream-name "$WSTREAM" --region "$WEST"
STREAM_ARN="$(aws kinesis describe-stream --stream-name "$STREAM" --region "$REGION" \
  --query 'StreamDescription.StreamARN' --output text)"
ARCHIVE_ARN="$(aws kinesis describe-stream --stream-name "$ARCHIVE" --region "$REGION" \
  --query 'StreamDescription.StreamARN' --output text)"
WSTREAM_ARN="$(aws kinesis describe-stream --stream-name "$WSTREAM" --region "$WEST" \
  --query 'StreamDescription.StreamARN' --output text)"

# --- the relay role CloudWatch Logs writes through -----------------------------------------
aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"logs.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
python3 - "$ROLE" "$STREAM_ARN" "$ARCHIVE_ARN" "$WSTREAM_ARN" <<'PY'
import json, sys, boto3
role = sys.argv[1]
arns = sys.argv[2:]
boto3.client("iam").put_role_policy(
    RoleName=role, PolicyName="relay",
    PolicyDocument=json.dumps({"Version": "2012-10-17", "Statement": [{
        "Effect": "Allow",
        "Action": ["kinesis:PutRecord", "kinesis:PutRecords", "kinesis:DescribeStream"],
        "Resource": arns}]}))
PY
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

# --- application log groups ----------------------------------------------------------------
create_group() {  # name, class, retention, region
  aws logs create-log-group --log-group-name "$1" --log-group-class "$2" --region "$4" >/dev/null
  aws logs put-retention-policy --log-group-name "$1" --retention-in-days "$3" --region "$4" >/dev/null
  aws logs create-log-stream --log-group-name "$1" --log-stream-name application --region "$4" >/dev/null
}
create_group "$G_CHECKOUT"  STANDARD           30 "$REGION"
create_group "$G_PAYMENTS"  STANDARD           30 "$REGION"
create_group "$G_INVENTORY" STANDARD           14 "$REGION"
create_group "$G_PRICING"   INFREQUENT_ACCESS  90 "$REGION"
create_group "$G_VENDOR"    STANDARD            7 "$REGION"
create_group "$G_EDGE"      STANDARD           30 "$WEST"

NOW="$(python3 -c 'import time;print(int(time.time()*1000))')"
for g in "$G_CHECKOUT" "$G_PAYMENTS" "$G_INVENTORY" "$G_PRICING" "$G_VENDOR"; do
  aws logs put-log-events --log-group-name "$g" --log-stream-name application --region "$REGION" \
    --log-events "timestamp=${NOW},message=INFO service started" \
                 "timestamp=$((NOW+1)),message=INFO handled request id=7311" >/dev/null
done
aws logs put-log-events --log-group-name "$G_EDGE" --log-stream-name application --region "$WEST" \
  --log-events "timestamp=${NOW},message=INFO service started" \
               "timestamp=$((NOW+1)),message=INFO handled request id=7311" >/dev/null

# IAM role propagation before CloudWatch Logs will accept it on a subscription filter.
for _ in $(seq 1 20); do
  if aws logs put-subscription-filter --log-group-name "$G_CHECKOUT" --filter-name relay \
       --filter-pattern 'ERROR' --destination-arn "$STREAM_ARN" --role-arn "$ROLE_ARN" \
       --region "$REGION" >/dev/null 2>&1; then break; fi
  sleep 5
done
aws logs put-subscription-filter --log-group-name "$G_PAYMENTS" --filter-name relay \
  --filter-pattern '' --destination-arn "$ARCHIVE_ARN" --role-arn "$ROLE_ARN" --region "$REGION" >/dev/null

python3 - "$REGION" "$ACCT" "$SUF" "$STREAM" "$STREAM_ARN" "$ARCHIVE" "$ROLE" "$ROLE_ARN" \
         "$G_CHECKOUT" "$G_PAYMENTS" "$G_INVENTORY" "$G_PRICING" "$G_VENDOR" \
         "$WEST" "$WSTREAM" "$WSTREAM_ARN" "$G_EDGE" <<'PY'
import json, sys, boto3
region, acct, suf = sys.argv[1], sys.argv[2], sys.argv[3]
stream, stream_arn, archive, role, role_arn = sys.argv[4:9]
relayed = sys.argv[9:13]
vendor = sys.argv[13]
west, wstream, wstream_arn, g_edge = sys.argv[14:18]
logs = boto3.client("logs", region_name=region)
logs_w = boto3.client("logs", region_name=west)
kin = boto3.client("kinesis", region_name=region)
kin_w = boto3.client("kinesis", region_name=west)
iam = boto3.client("iam")
sd = kin.describe_stream(StreamName=stream)["StreamDescription"]
wsd = kin_w.describe_stream(StreamName=wstream)["StreamDescription"]
r = iam.get_role(RoleName=role)["Role"]


def snapshot(client, rgn):
    out = {}
    for g in client.describe_log_groups(logGroupNamePrefix="/svc/")["logGroups"]:
        arn = (g.get("logGroupArn") or g["arn"]).rstrip("*").rstrip(":")
        out[g["logGroupName"]] = {
            "arn": arn,
            "region": rgn,
            "creationTime": g["creationTime"],
            "retentionInDays": g.get("retentionInDays"),
            "logGroupClass": g.get("logGroupClass"),
            "kmsKeyId": g.get("kmsKeyId"),
            "dataProtectionStatus": g.get("dataProtectionStatus"),
            "tags": client.list_tags_for_resource(resourceArn=arn).get("tags", {}),
        }
    return out


seeded = snapshot(logs, region)
seeded.update(snapshot(logs_w, west))
json.dump({"region": region, "account": acct, "suffix": suf,
           "stream_name": stream, "stream_arn": stream_arn, "archive_name": archive,
           "stream_created": sd["StreamCreationTimestamp"].isoformat(),
           "role_name": role, "role_arn": role_arn,
           "role_id": r["RoleId"], "role_created": r["CreateDate"].isoformat(),
           "relayed_groups": relayed, "vendor_group": vendor,
           "west_region": west, "west_stream_name": wstream, "west_stream_arn": wstream_arn,
           "west_stream_created": wsd["StreamCreationTimestamp"].isoformat(),
           "west_relayed_groups": [g_edge],
           "seeded_groups": seeded},
          open("seed_state.json", "w"), indent=2)
PY

echo "seeded ${STREAM} + 5 /svc/ log groups, and ${WSTREAM} + ${G_EDGE} in ${WEST}"
