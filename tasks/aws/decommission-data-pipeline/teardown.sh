#!/usr/bin/env bash
# Teardown for ext_archit_decommission_data (bundle): delete every resource the stack created
# in BOTH regions, regardless of how far the agent got. Idempotent; tolerant of already-absent
# resources. Precise deletes from ./seed_state.json when present, then a by-name prefix sweep
# as a belt-and-suspenders. Finally removes seed_state.json.
set -uo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
PARAMS="seed_state.json"
echo "==> teardown ext_archit_decommission_data"
get() { python3 -c "import json;d=json.load(open('$PARAMS'));print(d$1)" 2>/dev/null || true; }

if [[ -f "$PARAMS" ]]; then
  PRIMARY="$(get "['primary_region']")"; SECONDARY="$(get "['secondary_region']")"
  PREFIX="$(get "['prefix']")"
  # precise deletes by params
  aws dynamodb delete-table --table-name "$(get "['home']['table']")" --region "$PRIMARY" >/dev/null 2>&1 || true
  aws kinesis delete-stream --stream-name "$(get "['home']['stream']")" --region "$PRIMARY" >/dev/null 2>&1 || true
  aws ecr delete-repository --repository-name "$(get "['home']['repo']")" --force --region "$PRIMARY" >/dev/null 2>&1 || true
  aws sqs delete-queue --queue-url "$(get "['home']['queue_url']")" --region "$PRIMARY" >/dev/null 2>&1 || true
  aws dynamodb delete-table --table-name "$(get "['away']['table']")" --region "$SECONDARY" >/dev/null 2>&1 || true
  aws kinesis delete-stream --stream-name "$(get "['away']['stream']")" --region "$SECONDARY" >/dev/null 2>&1 || true
else
  # no seed_state — fall back to the region pair + stable stem for the sweep
  PRIMARY="$AWS_REGION"
  if [[ "$PRIMARY" == "us-west-2" ]]; then SECONDARY="us-east-1"; else SECONDARY="us-west-2"; fi
  PREFIX="adt-"
fi
# never sweep with an empty prefix (would match every resource in the account)
[[ -n "$PREFIX" ]] || PREFIX="adt-"

# belt-and-suspenders prefix sweep across both regions (in case ids drifted)
for region in "$PRIMARY" "$SECONDARY"; do
  for t in $(aws dynamodb list-tables --region "$region" --query "TableNames[?contains(@,'${PREFIX}')]" --output text 2>/dev/null); do
    aws dynamodb delete-table --table-name "$t" --region "$region" >/dev/null 2>&1 || true
  done
  for s in $(aws kinesis list-streams --region "$region" --query "StreamNames[?contains(@,'${PREFIX}')]" --output text 2>/dev/null); do
    aws kinesis delete-stream --stream-name "$s" --region "$region" >/dev/null 2>&1 || true
  done
  for r in $(aws ecr describe-repositories --region "$region" --query "repositories[?contains(repositoryName,'${PREFIX}')].repositoryName" --output text 2>/dev/null); do
    aws ecr delete-repository --repository-name "$r" --force --region "$region" >/dev/null 2>&1 || true
  done
  for u in $(aws sqs list-queues --queue-name-prefix "$PREFIX" --region "$region" --query 'QueueUrls' --output text 2>/dev/null); do
    aws sqs delete-queue --queue-url "$u" --region "$region" >/dev/null 2>&1 || true
  done
done

rm -f "$PARAMS"
echo "==> teardown complete"
exit 0
