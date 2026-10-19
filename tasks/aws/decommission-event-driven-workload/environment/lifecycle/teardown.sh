#!/usr/bin/env bash
# Deletes every resource the setup created in both regions, then sweeps by
# prefix in case any identifiers changed, and removes seed_state.json.
# Tolerates resources that are already gone.
set -uo pipefail
PARAMS="seed_state.json"
echo "==> teardown decommission-event-driven-workload"
[[ -f "$PARAMS" ]] || { echo "no seed_state.json"; exit 0; }
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null)}"
get() { python3 -c "import json;d=json.load(open('$PARAMS'));print(d$1)" 2>/dev/null || true; }

PRIMARY="$(get "['primary_region']")"; SECONDARY="$(get "['secondary_region']")"
PREFIX="$(get "['prefix']")"

# Delete the resources recorded in seed_state.json.
aws events delete-rule --name "$(get "['home']['rule']")" --region "$PRIMARY" >/dev/null 2>&1 || true
aws sqs delete-queue --queue-url "$(get "['home']['queue_url']")" --region "$PRIMARY" >/dev/null 2>&1 || true
aws sns delete-topic --topic-arn "arn:aws:sns:${PRIMARY}:${ACCOUNT_ID}:$(get "['home']['topic']")" --region "$PRIMARY" >/dev/null 2>&1 || true
aws events delete-rule --name "$(get "['away']['rule']")" --region "$SECONDARY" >/dev/null 2>&1 || true
aws sqs delete-queue --queue-url "$(get "['away']['queue_url']")" --region "$SECONDARY" >/dev/null 2>&1 || true

# Prefix sweep across both regions.
for region in "$PRIMARY" "$SECONDARY"; do
  for name in $(aws events list-rules --name-prefix "$PREFIX" --region "$region" --query "Rules[?contains(Name,'${PREFIX}')].Name" --output text 2>/dev/null); do
    # Remove any targets before deleting the rule.
    ids=$(aws events list-targets-by-rule --rule "$name" --region "$region" --query 'Targets[].Id' --output text 2>/dev/null)
    [[ -n "$ids" ]] && aws events remove-targets --rule "$name" --ids $ids --region "$region" >/dev/null 2>&1 || true
    aws events delete-rule --name "$name" --region "$region" >/dev/null 2>&1 || true
  done
  for u in $(aws sqs list-queues --queue-name-prefix "$PREFIX" --region "$region" --query 'QueueUrls' --output text 2>/dev/null); do
    aws sqs delete-queue --queue-url "$u" --region "$region" >/dev/null 2>&1 || true
  done
  for arn in $(aws sns list-topics --region "$region" --query "Topics[?contains(TopicArn,'${PREFIX}')].TopicArn" --output text 2>/dev/null); do
    aws sns delete-topic --topic-arn "$arn" --region "$region" >/dev/null 2>&1 || true
  done
done

rm -f "$PARAMS"
echo "==> teardown complete"
exit 0
