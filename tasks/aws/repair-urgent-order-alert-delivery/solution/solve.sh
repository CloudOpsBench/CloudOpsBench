#!/usr/bin/env bash
# Repoints the queue policy at the current topic, enables RawMessageDelivery and
# corrects the priority filter value. Resources are discovered by name at runtime.
set -euo pipefail
export MSYS_NO_PATHCONV=1

TOPIC_ARN=$(aws sns list-topics \
  --query "Topics[?contains(TopicArn, 'fulfillment-alerts-topic-')].TopicArn | [0]" \
  --output text)
QUEUE_URL=$(aws sqs list-queues --queue-name-prefix "oncall-escalation-queue-" \
  --query "QueueUrls[0]" --output text)
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)
SUB_ARN=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
  --query "Subscriptions[?Protocol=='sqs'].SubscriptionArn | [0]" --output text)

# Point the queue policy's SourceArn condition at the current topic.
python3 - "$QUEUE_ARN" "$TOPIC_ARN" > queue-policy.json <<'PY'
import json
import sys

queue_arn, topic_arn = sys.argv[1], sys.argv[2]
policy = {
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AllowSNSDelivery",
        "Effect": "Allow",
        "Principal": {"Service": "sns.amazonaws.com"},
        "Action": "sqs:SendMessage",
        "Resource": queue_arn,
        "Condition": {"ArnEquals": {"aws:SourceArn": topic_arn}},
    }],
}
print(json.dumps({"Policy": json.dumps(policy)}))
PY
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" --attributes file://queue-policy.json
rm -f queue-policy.json

# Deliver the plain message body instead of the SNS notification envelope.
aws sns set-subscription-attributes --subscription-arn "$SUB_ARN" \
  --attribute-name RawMessageDelivery --attribute-value true

# SetSubscriptionAttributes replaces the whole FilterPolicy, so read the current
# policy and change only the priority clause.
CURRENT_FP=$(aws sns get-subscription-attributes --subscription-arn "$SUB_ARN" \
  --query "Attributes.FilterPolicy" --output text)
python3 - "$CURRENT_FP" > filter-fix.json <<'PY'
import json
import sys

fp = json.loads(sys.argv[1])
for clause in fp.get("$or", []):
    if "priority" in clause:
        clause["priority"] = ["urgent"]
print(json.dumps(fp))
PY
aws sns set-subscription-attributes --subscription-arn "$SUB_ARN" \
  --attribute-name FilterPolicy --attribute-value file://filter-fix.json
rm -f filter-fix.json

echo "fulfillment-alert pipeline repaired: queue policy repointed at the"
echo "real topic, RawMessageDelivery enabled, and the priority filter"
echo "corrected to the real producer convention (ComplianceAudit clause"
echo "preserved)"
