#!/usr/bin/env bash
# Golden reference solution for aws_task05 (deterministic, no model). Tightens the DLQ's
# redrive-allow to byQueue permitting BOTH vera-orders-main AND the hidden vera-orders-retry
# (the reverse-lookup discovery). Sets the attribute DIRECTLY via the SQS API — no
# `terraform apply`, so the golden never depends on setup's tfstate/provider-cache being
# present in this phase and never re-plans the queue (which, with a missing state, would try
# to RE-CREATE an existing queue and crash). The grader reads the live RedriveAllowPolicy;
# teardown deletes queues by name, so a CLI-applied policy is fully covered.
# CWD = runspace root.
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
