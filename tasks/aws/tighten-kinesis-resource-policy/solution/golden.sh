#!/usr/bin/env bash
# Golden reference solution for aws_task20 (deterministic, no model). Tightens the
# events-stream resource policy to least privilege: the producer may write
# (PutRecord/PutRecords), the hidden enhanced-fan-out consumer (vera-analytics-consumer,
# the reverse-lookup discovery) keeps its reads, and the wide-open account-root grant is
# removed (so an outsider is denied). Sets the policy DIRECTLY via the Kinesis API
# (put-resource-policy) — NO `terraform apply`, so the golden never depends on setup's
# tfstate/provider-cache being present in this phase and never re-plans the stream
# (which, with a missing state, would try to RE-CREATE the existing stream and crash).
# The grader is behavioural (assumes each role and makes real calls); teardown deletes
# resources by name, so a CLI-applied policy is fully covered. CWD = runspace root.
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
SFX="$AWS_REGION"
STREAM="vera-events-stream-${SFX}"
PRODUCER_ARN="arn:aws:iam::${ACCOUNT_ID}:role/vera-events-producer-${SFX}"
CONSUMER_ARN="arn:aws:iam::${ACCOUNT_ID}:role/vera-analytics-consumer-${SFX}"

STREAM_ARN=$(aws kinesis describe-stream-summary --stream-name "$STREAM" \
  --query 'StreamDescriptionSummary.StreamARN' --output text)

POLICY_FILE=$(mktemp)
python3 - "$POLICY_FILE" "$PRODUCER_ARN" "$CONSUMER_ARN" "$STREAM_ARN" <<'PY'
import json, sys
out, producer, consumer, arn = sys.argv[1:5]
policy = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowEventsProducerWrite",
            "Effect": "Allow",
            "Principal": {"AWS": producer},
            "Action": ["kinesis:PutRecord", "kinesis:PutRecords"],
            "Resource": arn,
        },
        {
            "Sid": "AllowAnalyticsConsumerRead",
            "Effect": "Allow",
            "Principal": {"AWS": consumer},
            "Action": [
                "kinesis:GetRecords",
                "kinesis:GetShardIterator",
                "kinesis:DescribeStream",
                "kinesis:DescribeStreamSummary",
                "kinesis:ListShards",
            ],
            "Resource": arn,
        },
    ],
}
json.dump(policy, open(out, "w"))
PY

aws kinesis put-resource-policy --resource-arn "$STREAM_ARN" \
  --policy "file://$POLICY_FILE" --region "$AWS_REGION"
rm -f "$POLICY_FILE"

echo "==> Solution applied: ${STREAM} resource policy -> producer write only, analytics-consumer reads kept, wide-open grant removed"
