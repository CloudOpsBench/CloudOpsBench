#!/usr/bin/env bash
# Best-effort cleanup. Never fails.
set -uo pipefail
export MSYS_NO_PATHCONV=1

[ -f seed_state.json ] || exit 0
get() { python3 -c "import json;print(json.load(open('seed_state.json')).get('$1',''))" 2>/dev/null || true; }

BKT=$(get bucket)
ARCH_URL=$(get archiver_queue_url)
RET_URL=$(get retention_queue_url)
BUS=$(get bus)
CAP=$(get capture_rule)
TAG=$(get tagger_rule)
ROLE=$(get ingest_role)

# Rules can end up on either bus (the fix re-homes the capture rule); clear both.
for b in "$BUS" ""; do
  for r in "$CAP" "$TAG"; do
    [ -n "$r" ] || continue
    if [ -n "$b" ]; then
      IDS=$(aws events list-targets-by-rule --rule "$r" --event-bus-name "$b" \
        --query 'Targets[].Id' --output text 2>/dev/null || true)
      [ -n "${IDS:-}" ] && [ "$IDS" != "None" ] && \
        aws events remove-targets --rule "$r" --event-bus-name "$b" --ids $IDS >/dev/null 2>&1 || true
      aws events delete-rule --name "$r" --event-bus-name "$b" >/dev/null 2>&1 || true
    else
      IDS=$(aws events list-targets-by-rule --rule "$r" --query 'Targets[].Id' --output text 2>/dev/null || true)
      [ -n "${IDS:-}" ] && [ "$IDS" != "None" ] && \
        aws events remove-targets --rule "$r" --ids $IDS >/dev/null 2>&1 || true
      aws events delete-rule --name "$r" >/dev/null 2>&1 || true
    fi
  done
done
[ -n "$BUS" ] && aws events delete-event-bus --name "$BUS" >/dev/null 2>&1 || true

SEALER_ARN=$(get sealer_state_machine_arn)
SEALER_ROLE=$(get sealer_role)
SSM_PARAM=$(get ssm_param)
[ -n "$SEALER_ARN" ] && aws stepfunctions delete-state-machine --state-machine-arn "$SEALER_ARN" >/dev/null 2>&1 || true
if [ -n "$SEALER_ROLE" ]; then
  for p in $(aws iam list-role-policies --role-name "$SEALER_ROLE" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
    aws iam delete-role-policy --role-name "$SEALER_ROLE" --policy-name "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$SEALER_ROLE" >/dev/null 2>&1 || true
fi
[ -n "$SSM_PARAM" ] && aws ssm delete-parameter --name "$SSM_PARAM" >/dev/null 2>&1 || true

TOPIC_ARN=$(get alert_topic_arn)
REC=$(get recorder_rule)
DLQ_URL=$(get dlq_queue_url)
if [ -n "$REC" ] && [ -n "$BUS" ]; then
  IDS=$(aws events list-targets-by-rule --rule "$REC" --event-bus-name "$BUS" \
    --query 'Targets[].Id' --output text 2>/dev/null || true)
  [ -n "${IDS:-}" ] && [ "$IDS" != "None" ] && \
    aws events remove-targets --rule "$REC" --event-bus-name "$BUS" --ids $IDS >/dev/null 2>&1 || true
  aws events delete-rule --name "$REC" --event-bus-name "$BUS" >/dev/null 2>&1 || true
fi
if [ -n "$TOPIC_ARN" ]; then
  for S in $(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
      --query 'Subscriptions[].SubscriptionArn' --output text 2>/dev/null || true); do
    [ "$S" != "PendingConfirmation" ] && aws sns unsubscribe --subscription-arn "$S" >/dev/null 2>&1 || true
  done
  aws sns delete-topic --topic-arn "$TOPIC_ARN" >/dev/null 2>&1 || true
fi
[ -n "$DLQ_URL" ] && aws sqs delete-queue --queue-url "$DLQ_URL" >/dev/null 2>&1 || true

[ -n "$BKT" ] && aws s3 rm "s3://$BKT" --recursive >/dev/null 2>&1 || true
[ -n "$BKT" ] && aws s3api delete-bucket --bucket "$BKT" >/dev/null 2>&1 || true

for u in "$ARCH_URL" "$RET_URL"; do
  [ -n "$u" ] && aws sqs delete-queue --queue-url "$u" >/dev/null 2>&1 || true
done

if [ -n "$ROLE" ]; then
  for p in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$p" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
fi

echo "teardown complete"
exit 0
