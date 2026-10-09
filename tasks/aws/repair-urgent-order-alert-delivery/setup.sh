#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
SFX="${RANDOM}${RANDOM}"
TOPIC="fulfillment-alerts-topic-$SFX"
QUEUE="oncall-escalation-queue-$SFX"

ACCT=$(aws sts get-caller-identity --query Account --output text)
retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 10 ] && return 1; sleep 5; done; }

TOPIC_ARN=$(retry aws sns create-topic --name "$TOPIC" --query TopicArn --output text)
STALE_TOPIC_ARN="arn:aws:sns:$REGION:$ACCT:fulfillment-alerts-topic-retired-$SFX"

# --- Queue (subscription target).
QUEUE_URL=$(retry aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

python3 - "$QUEUE_ARN" "$STALE_TOPIC_ARN" > queue-policy.json <<'PY'
import json
import sys

queue_arn, stale_topic_arn = sys.argv[1], sys.argv[2]
policy = {
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AllowSNSDelivery",
        "Effect": "Allow",
        "Principal": {"Service": "sns.amazonaws.com"},
        "Action": "sqs:SendMessage",
        "Resource": queue_arn,
        "Condition": {"ArnEquals": {"aws:SourceArn": stale_topic_arn}},
    }],
}
print(json.dumps({"Policy": json.dumps(policy)}))
PY
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes file://queue-policy.json
rm -f queue-policy.json

SUB_ARN=$(retry aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
  --notification-endpoint "$QUEUE_ARN" --query SubscriptionArn --output text)

python3 - > filter-policy.json <<'PY'
import json

policy = {"$or": [{"priority": ["URGENT"]}, {"category": ["ComplianceAudit"]}]}
print(json.dumps(policy))
PY
retry aws sns set-subscription-attributes --subscription-arn "$SUB_ARN" \
  --attribute-name FilterPolicy --attribute-value file://filter-policy.json
rm -f filter-policy.json

cat > seed_state.json <<EOF
{
  "suffix": "$SFX",
  "region": "$REGION",
  "topic_arn": "$TOPIC_ARN",
  "queue_url": "$QUEUE_URL",
  "queue_arn": "$QUEUE_ARN",
  "subscription_arn": "$SUB_ARN"
}
EOF

echo "seeded fulfillment-alert pipeline $SFX (case-mismatched priority filter,"
echo "stale queue-policy SourceArn, RawMessageDelivery off, and a protected"
echo "ComplianceAudit filter clause sharing the same FilterPolicy)"
