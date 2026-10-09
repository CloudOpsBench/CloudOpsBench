#!/usr/bin/env bash
# Deletes the vera2- SNS topics, SQS queues, Kinesis streams and HealthOmics
# sequence stores.
set -uo pipefail
export AWS_PAGER=""
REGION="${AWS_REGION:-us-east-1}"
for arn in $(aws sns list-topics --region "$REGION" --query "Topics[].TopicArn" --output text 2>/dev/null | tr '\t' '\n' | grep ':vera2-'); do
  aws sns delete-topic --topic-arn "$arn" --region "$REGION" 2>/dev/null || true
done
for url in $(aws sqs list-queues --queue-name-prefix vera2- --region "$REGION" --query "QueueUrls" --output text 2>/dev/null | tr '\t' '\n' | grep -Ev '^(None)?$'); do
  aws sqs delete-queue --queue-url "$url" --region "$REGION" 2>/dev/null || true
done
for name in $(aws kinesis list-streams --region "$REGION" --query 'StreamNames' --output text 2>/dev/null | tr '\t' '\n' | grep '^vera2-'); do
  aws kinesis delete-stream --stream-name "$name" --region "$REGION" 2>/dev/null || true
  aws kinesis wait stream-not-exists --stream-name "$name" --region "$REGION" 2>/dev/null || true
done
for sid in $(aws omics list-sequence-stores --region "$REGION" --query "sequenceStores[?starts_with(name,'vera2-')].id" --output text 2>/dev/null | tr '\t' '\n' | grep -Ev '^(None)?$'); do
  ap=$(aws omics get-sequence-store --id "$sid" --region "$REGION" --query 's3Access.s3AccessPointArn' --output text 2>/dev/null)
  [ -n "$ap" ] && aws omics delete-s3-access-policy --s3-access-point-arn "$ap" --region "$REGION" 2>/dev/null || true
  aws omics delete-sequence-store --id "$sid" --region "$REGION" 2>/dev/null || true
done
echo "torn down vera2 SNS, SQS, Kinesis, and HealthOmics resources"
