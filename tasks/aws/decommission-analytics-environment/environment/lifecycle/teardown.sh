#!/usr/bin/env bash
# Deletes every resource setup.sh created in both regions, tolerating ones that are
# already gone, then sweeps by prefix and removes ./seed_state.json.
set -uo pipefail
PARAMS="seed_state.json"
echo "==> teardown decommission-analytics-environment"
[[ -f "$PARAMS" ]] || { echo "no params"; exit 0; }
get() { python3 -c "import json;d=json.load(open('$PARAMS'));print(d$1)" 2>/dev/null || true; }

PRIMARY="$(get "['primary_region']")"; SECONDARY="$(get "['secondary_region']")"
PREFIX="$(get "['prefix']")"; RUN_ID="$(get "['run_id']")"

# Delete the resources recorded in seed_state.json.
aws athena delete-work-group --work-group "$(get "['home']['workgroup']")" --recursive-delete-option --region "$PRIMARY" >/dev/null 2>&1 || true
aws secretsmanager delete-secret --secret-id "$(get "['home']['secret']")" --force-delete-without-recovery --region "$PRIMARY" >/dev/null 2>&1 || true
aws ssm delete-parameter --name "$(get "['home']['ssm_param']")" --region "$PRIMARY" >/dev/null 2>&1 || true
aws sqs delete-queue --queue-url "$(get "['home']['queue_url']")" --region "$PRIMARY" >/dev/null 2>&1 || true
aws athena delete-work-group --work-group "$(get "['away']['workgroup']")" --recursive-delete-option --region "$SECONDARY" >/dev/null 2>&1 || true
aws ssm delete-parameter --name "$(get "['away']['ssm_param']")" --region "$SECONDARY" >/dev/null 2>&1 || true

# Prefix sweep across both regions for anything the recorded names missed.
for region in "$PRIMARY" "$SECONDARY"; do
  for wg in $(aws athena list-work-groups --region "$region" --query "WorkGroups[?contains(Name,'${PREFIX}')].Name" --output text 2>/dev/null); do
    aws athena delete-work-group --work-group "$wg" --recursive-delete-option --region "$region" >/dev/null 2>&1 || true
  done
  for s in $(aws secretsmanager list-secrets --region "$region" --query "SecretList[?contains(Name,'${PREFIX}')].Name" --output text 2>/dev/null); do
    aws secretsmanager delete-secret --secret-id "$s" --force-delete-without-recovery --region "$region" >/dev/null 2>&1 || true
  done
  for par in $(aws ssm describe-parameters --region "$region" --query "Parameters[?contains(Name,'${RUN_ID}')].Name" --output text 2>/dev/null); do
    aws ssm delete-parameter --name "$par" --region "$region" >/dev/null 2>&1 || true
  done
  for u in $(aws sqs list-queues --queue-name-prefix "$PREFIX" --region "$region" --query 'QueueUrls' --output text 2>/dev/null); do
    aws sqs delete-queue --queue-url "$u" --region "$region" >/dev/null 2>&1 || true
  done
done

rm -f "$PARAMS"
echo "==> teardown complete"
exit 0
