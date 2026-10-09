#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
for url in $(aws sqs list-queues --queue-name-prefix vera2- --region "$REGION" --query 'QueueUrls' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true); do
  aws sqs delete-queue --queue-url "$url" --region "$REGION" 2>/dev/null || true
done
EP=$(aws mediaconvert describe-endpoints --region "$REGION" --query 'Endpoints[0].Url' --output text 2>/dev/null || true)
if [ -n "${EP:-}" ] && [ "$EP" != "None" ]; then
  for q in $(aws mediaconvert --endpoint-url "$EP" --region "$REGION" list-queues --query "Queues[?starts_with(Name,'vera2-')].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true); do
    aws mediaconvert --endpoint-url "$EP" --region "$REGION" delete-queue --name "$q" 2>/dev/null || true
  done
fi
echo "torn down vera2 queues in $REGION"
