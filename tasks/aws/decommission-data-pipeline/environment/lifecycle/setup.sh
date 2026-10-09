#!/usr/bin/env bash
# ext_archit_decommission_data bundle setup — discovery-ceiling decommission. Hand-build a
# small stack via the CLI, every resource carrying a per-run prefix `adt-<hex>` in its NAME
# ONLY (NO TAGS: tagging would let the agent enumerate the whole stack via the Resource
# Groups Tagging API in one call — the difficulty is that the agent must DISCOVER each
# resource itself, per-service, per-region). The traps: (1) orphans in a DIFFERENT region
# (a per-region sweep misses them), and (2) niche/less-enumerated services (Kinesis streams,
# ECR repositories). The grader checks COMPLETENESS across BOTH regions + all services.
# Cheap (all near-free, short-lived). Writes ground truth to ./seed_state.json (CWD).
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
PRIMARY="$AWS_REGION"
if [[ "$PRIMARY" == "us-west-2" ]]; then SECONDARY="us-east-1"; else SECONDARY="us-west-2"; fi
TASK_TAG="ext_archit_decommission_data"

RUN_ID="$(printf '%04x' $((RANDOM % 65536)))"
PREFIX="adt-${RUN_ID}"
TABLE="${PREFIX}-table"; STREAM="${PREFIX}-stream"
REPO="${PREFIX}-repo"; QUEUE="${PREFIX}-queue"
W_TABLE="${PREFIX}-table"; W_STREAM="${PREFIX}-stream"

echo "==> setup $TASK_TAG (account $ACCOUNT_ID, home $PRIMARY, prefix $PREFIX)"

# ── home region ($PRIMARY): obvious resources + niche orphans ──────────────────
aws dynamodb create-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "$PRIMARY" >/dev/null

# niche: a Kinesis stream (single shard) — easy to forget, not in the usual sweep
aws kinesis create-stream --stream-name "$STREAM" --shard-count 1 --region "$PRIMARY" >/dev/null

# niche: an ECR repository (empty) — another less-enumerated service
aws ecr create-repository --repository-name "$REPO" --region "$PRIMARY" >/dev/null

QUEUE_URL="$(aws sqs create-queue --queue-name "$QUEUE" --region "$PRIMARY" --query 'QueueUrl' --output text)"

# ── SECONDARY region ($SECONDARY): the orphans in the "forgotten" region ────────
aws dynamodb create-table --table-name "$W_TABLE" \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region "$SECONDARY" >/dev/null
aws kinesis create-stream --stream-name "$W_STREAM" --shard-count 1 --region "$SECONDARY" >/dev/null

# Wait for async-created resources to reach ACTIVE so they're in a deletable state — a table
# still CREATING rejects delete-table, which would otherwise leave an orphan the agent "deleted".
aws dynamodb wait table-exists --table-name "$TABLE" --region "$PRIMARY" 2>/dev/null || true
aws dynamodb wait table-exists --table-name "$W_TABLE" --region "$SECONDARY" 2>/dev/null || true
aws kinesis wait stream-exists --stream-name "$STREAM" --region "$PRIMARY" 2>/dev/null || true
aws kinesis wait stream-exists --stream-name "$W_STREAM" --region "$SECONDARY" 2>/dev/null || true

echo "  home($PRIMARY): table=$TABLE stream=$STREAM repo=$REPO queue=$QUEUE"
echo "  away($SECONDARY): table=$W_TABLE stream=$W_STREAM"

python3 - <<PY
import json
json.dump({
  "project": "${ACCOUNT_ID}", "account_id": "${ACCOUNT_ID}", "region": "${PRIMARY}",
  "prefix": "${PREFIX}", "run_id": "${RUN_ID}",
  "primary_region": "${PRIMARY}", "secondary_region": "${SECONDARY}",
  "home": {"table": "${TABLE}", "stream": "${STREAM}", "repo": "${REPO}",
           "queue_url": "${QUEUE_URL}"},
  "away": {"table": "${W_TABLE}", "stream": "${W_STREAM}"},
}, open("seed_state.json", "w"), indent=2)
print("  wrote seed_state.json")
PY
echo "==> setup complete — fully decommission '$PREFIX' (nothing left behind, anywhere)"
