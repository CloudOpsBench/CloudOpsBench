#!/usr/bin/env bash
# Set the DLQ's redrive-allow policy to byQueue for the main and retry queues. Uses
# the SQS API directly rather than Terraform so it does not depend on the setup
# phase's Terraform state.
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
export AWS_DEFAULT_REGION="$AWS_REGION"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
SFX="$AWS_REGION"
DLQ="vera-orders-dlq-${SFX}"
MAIN_ARN="arn:aws:sqs:${SFX}:${ACCOUNT_ID}:vera-orders-main-${SFX}"
RETRY_ARN="arn:aws:sqs:${SFX}:${ACCOUNT_ID}:vera-orders-retry-${SFX}"

DLQ_URL=$(aws sqs get-queue-url --queue-name "$DLQ" --query QueueUrl --output text)

RAP="{\"redrivePermission\":\"byQueue\",\"sourceQueueArns\":[\"${MAIN_ARN}\",\"${RETRY_ARN}\"]}"
ATTR_FILE=$(mktemp)
python3 - "$ATTR_FILE" "$RAP" <<'PY'
import json, sys
out, rap = sys.argv[1], sys.argv[2]
json.dump({"RedriveAllowPolicy": rap}, open(out, "w"))
PY
aws sqs set-queue-attributes --queue-url "$DLQ_URL" --attributes "file://$ATTR_FILE"
rm -f "$ATTR_FILE"

echo "==> Solution applied: ${DLQ} redrive-allow -> byQueue permits vera-orders-main + vera-orders-retry"
