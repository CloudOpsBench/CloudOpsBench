#!/usr/bin/env bash
# Replace the stream's resource policy with producer write access and analytics
# consumer read access. Uses the Kinesis API directly rather than Terraform so it
# does not depend on the setup phase's Terraform state.
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

echo "==> Updated ${STREAM} resource policy"
