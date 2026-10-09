#!/usr/bin/env bash
# Seeds an SNS topic and SQS queue with wildcard-principal policies, a Kinesis
# stream whose resource policy grants an external account, and a HealthOmics
# sequence store whose S3 access policy grants the same external account.
# Resource identifiers are written to seed_state.json.
set -euo pipefail
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"
SUF="${RANDOM}${RANDOM}"
EXT=127311923021
ACCT=$(aws sts get-caller-identity --query Account --output text)

TOPIC_ARN=$(aws sns create-topic --name "vera2-alerts-${SUF}" --region "$REGION" --query 'TopicArn' --output text)
aws sns set-topic-attributes --topic-arn "$TOPIC_ARN" --attribute-name Policy --region "$REGION" \
  --attribute-value "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Pub\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"*\"},\"Action\":\"SNS:Subscribe\",\"Resource\":\"${TOPIC_ARN}\"}]}"

QURL=$(aws sqs create-queue --queue-name "vera2-jobs-${SUF}" --region "$REGION" --query 'QueueUrl' --output text)
python3 - "$REGION" "$QURL" <<'PY'
import boto3, sys, json
r, url = sys.argv[1:3]
sqs = boto3.client("sqs", region_name=r)
qarn = sqs.get_queue_attributes(QueueUrl=url, AttributeNames=["QueueArn"])["Attributes"]["QueueArn"]
pol = {"Version": "2012-10-17", "Statement": [{"Sid": "Pub", "Effect": "Allow",
       "Principal": {"AWS": "*"}, "Action": "SQS:SendMessage", "Resource": qarn}]}
sqs.set_queue_attributes(QueueUrl=url, Attributes={"Policy": json.dumps(pol)})
PY
for i in $(seq 1 20); do
  aws sqs list-queues --queue-name-prefix "vera2-" --region "$REGION" --query "QueueUrls" --output text 2>/dev/null | grep -q "vera2-" && break
  sleep 3
done

KS="vera2-kstream-${SUF}"
aws kinesis create-stream --stream-name "$KS" --shard-count 1 --region "$REGION"
aws kinesis wait stream-exists --stream-name "$KS" --region "$REGION"
KARN=$(aws kinesis describe-stream-summary --stream-name "$KS" --region "$REGION" --query 'StreamDescriptionSummary.StreamARN' --output text)
aws kinesis put-resource-policy --resource-arn "$KARN" --region "$REGION" \
  --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"ExtPartner\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${EXT}:root\"},\"Action\":\"kinesis:GetRecords\",\"Resource\":\"${KARN}\"}]}"

OS=$(aws omics create-sequence-store --name "vera2-omstore-${SUF}" --region "$REGION" --query 'id' --output text)
AP=$(aws omics get-sequence-store --id "$OS" --region "$REGION" --query 's3Access.s3AccessPointArn' --output text)
RES="${AP}/object/${ACCT}/sequenceStore/${OS}/*"
aws omics put-s3-access-policy --s3-access-point-arn "$AP" --region "$REGION" \
  --s3-access-policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Own\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${ACCT}:root\"},\"Action\":[\"s3:GetObject\"],\"Resource\":\"${RES}\"},{\"Sid\":\"ExtPartner\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"arn:aws:iam::${EXT}:root\"},\"Action\":[\"s3:GetObject\"],\"Resource\":\"${RES}\"}]}"

python3 - "$REGION" "$ACCT" "$TOPIC_ARN" "$QURL" "$KS" "$KARN" "$OS" "$AP" "$EXT" <<'PY'
import json, sys
r, acct, topic, qurl, ks, karn, os_id, ap, ext = sys.argv[1:10]
json.dump({"region": r, "account": acct, "sns_topic_arn": topic, "sqs_queue_url": qurl,
           "kinesis_stream": ks, "kinesis_arn": karn, "omics_store_id": os_id, "omics_ap_arn": ap,
           "external_account": ext}, open("seed_state.json", "w"), indent=2)
PY
echo "seeded public SNS + public SQS (decoys) + external-account Kinesis resource-policy + HealthOmics S3 access policy in ${REGION}"
