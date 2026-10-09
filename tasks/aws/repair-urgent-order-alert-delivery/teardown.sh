#!/usr/bin/env bash
# Cleanup. Never fails; every step best-effort.
set -uo pipefail
export MSYS_NO_PATHCONV=1

get() { python3 -c "import json; print(json.load(open('seed_state.json'))['$1'])" 2>/dev/null || true; }

TOPIC_ARN=$(get topic_arn)
QUEUE_URL=$(get queue_url)
SUB_ARN=$(get subscription_arn)

[ -z "${TOPIC_ARN:-}" ] && exit 0

[ -n "${SUB_ARN:-}" ] && aws sns unsubscribe --subscription-arn "$SUB_ARN" >/dev/null 2>&1 || true
[ -n "${QUEUE_URL:-}" ] && aws sqs delete-queue --queue-url "$QUEUE_URL" >/dev/null 2>&1 || true
[ -n "${TOPIC_ARN:-}" ] && aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true

exit 0
