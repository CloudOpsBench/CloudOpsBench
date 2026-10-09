#!/usr/bin/env bash
# Replaces the SNS topic policy with an own-account grant, clears the SQS queue
# policy, deletes the Kinesis resource policy, and removes statements for
# principals outside this account from the HealthOmics S3 access policy.
set -uo pipefail
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"
ACCT=$(aws sts get-caller-identity --query Account --output text)

for arn in $(aws sns list-topics --region "$REGION" --query "Topics[].TopicArn" --output text 2>/dev/null | tr '\t' '\n' | grep ':vera2-'); do
  aws sns set-topic-attributes --topic-arn "$arn" --attribute-name Policy --region "$REGION" \
    --attribute-value "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Own\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${ACCT}:root\"},\"Action\":\"SNS:Publish\",\"Resource\":\"${arn}\"}]}" 2>/dev/null || true
done

for url in $(aws sqs list-queues --queue-name-prefix vera2- --region "$REGION" --query "QueueUrls" --output text 2>/dev/null | tr '\t' '\n' | grep -Ev '^(None)?$'); do
  python3 - "$REGION" "$url" <<'PY'
import boto3, sys
r, url = sys.argv[1:3]
boto3.client("sqs", region_name=r).set_queue_attributes(QueueUrl=url, Attributes={"Policy": ""})
PY
done

for name in $(aws kinesis list-streams --region "$REGION" --query 'StreamNames' --output text 2>/dev/null | tr '\t' '\n' | grep '^vera2-'); do
  arn="arn:aws:kinesis:${REGION}:${ACCT}:stream/${name}"
  aws kinesis delete-resource-policy --resource-arn "$arn" --region "$REGION" 2>/dev/null || true
done

for sid in $(aws omics list-sequence-stores --region "$REGION" --query "sequenceStores[?starts_with(name,'vera2-')].id" --output text 2>/dev/null | tr '\t' '\n' | grep -Ev '^(None)?$'); do
  ap=$(aws omics get-sequence-store --id "$sid" --region "$REGION" --query 's3Access.s3AccessPointArn' --output text 2>/dev/null)
  [ -n "$ap" ] || continue
  python3 - "$REGION" "$ACCT" "$ap" <<'PY'
import json, subprocess, sys
region, acct, ap = sys.argv[1:4]
def aws(*a):
    return subprocess.run(["aws", "--region", region, "--output", "json", *a], capture_output=True, text=True)
r = aws("omics", "get-s3-access-policy", "--s3-access-point-arn", ap)
if r.returncode != 0:
    sys.exit(0)
doc = json.loads(json.loads(r.stdout)["s3AccessPolicy"])
def acct_of(p):
    if p == "*":
        return "*"
    parts = str(p).split(":")
    if len(parts) >= 5 and parts[4].isdigit():
        return parts[4]
    return str(p) if str(p).isdigit() else None
sts = doc.get("Statement", [])
if isinstance(sts, dict):
    sts = [sts]
keep = []
for s in sts:
    pr = s.get("Principal")
    vals = []
    if isinstance(pr, dict):
        for v in pr.values():
            vals += v if isinstance(v, list) else [v]
    elif pr:
        vals = [pr]
    if vals and all(acct_of(v) == acct for v in vals):
        keep.append(s)
if keep:
    doc["Statement"] = keep
    out = aws("omics", "put-s3-access-policy", "--s3-access-point-arn", ap, "--s3-access-policy", json.dumps(doc))
else:
    out = aws("omics", "delete-s3-access-policy", "--s3-access-point-arn", ap)
if out.returncode != 0:
    sys.stderr.write(out.stderr)
    sys.exit(1)
PY
done
echo "revoked public/external access on vera2 SNS, SQS, Kinesis, and HealthOmics resources; own-account grants kept"
