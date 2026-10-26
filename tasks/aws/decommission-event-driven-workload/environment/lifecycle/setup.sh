#!/usr/bin/env bash
# Creates a small event-driven stack named with the prefix aeb-<region>, without
# tags: an EventBridge rule, SQS queue and SNS topic in the home region, and an
# EventBridge rule and SQS queue in a second region. Writes seed_state.json.
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
PRIMARY="$AWS_REGION"
if [[ "$PRIMARY" == "us-west-2" ]]; then SECONDARY="us-east-1"; else SECONDARY="us-west-2"; fi

PREFIX="aeb-${PRIMARY}"
RULE="${PREFIX}-rule"; QUEUE="${PREFIX}-queue"; TOPIC="${PREFIX}-topic"
W_RULE="${PREFIX}-rule"; W_QUEUE="${PREFIX}-queue"

echo "==> setup decommission-event-driven-workload (home $PRIMARY, prefix $PREFIX)"

# Home region. The rule has no targets, so it needs no role; it is disabled so
# it never fires.
aws events put-rule --name "$RULE" --schedule-expression "rate(1 day)" --state DISABLED \
  --region "$PRIMARY" >/dev/null
QUEUE_URL="$(aws sqs create-queue --queue-name "$QUEUE" --region "$PRIMARY" --query 'QueueUrl' --output text)"
aws sns create-topic --name "$TOPIC" --region "$PRIMARY" >/dev/null

# Second region: an EventBridge rule and an SQS queue.
aws events put-rule --name "$W_RULE" --schedule-expression "rate(1 day)" --state DISABLED \
  --region "$SECONDARY" >/dev/null
W_QUEUE_URL="$(aws sqs create-queue --queue-name "$W_QUEUE" --region "$SECONDARY" --query 'QueueUrl' --output text)"

echo "  home($PRIMARY): rule=$RULE queue=$QUEUE topic=$TOPIC"
echo "  away($SECONDARY): rule=$W_RULE queue=$W_QUEUE"

python3 - <<PY
import json
json.dump({
  "prefix": "${PREFIX}",
  "primary_region": "${PRIMARY}", "secondary_region": "${SECONDARY}",
  "home": {"rule": "${RULE}", "queue_url": "${QUEUE_URL}", "topic": "${TOPIC}"},
  "away": {"rule": "${W_RULE}", "queue_url": "${W_QUEUE_URL}"},
}, open("seed_state.json", "w"), indent=2)
print("  wrote seed_state.json")
PY
echo "==> setup complete — fully decommission '$PREFIX' (nothing left behind, anywhere)"
