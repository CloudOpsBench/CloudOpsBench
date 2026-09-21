#!/usr/bin/env bash
# ext_archit_decommission_analytics bundle setup — discovery-ceiling decommission (AWS port of
# task41/43 family). Hand-build a small analytics stack via the CLI, every resource carrying a
# fixed prefix `aaq-7c21`. The agent is told to FULLY decommission it (nothing left behind).
# The trap is the discovery ceiling: the obvious resources live in the home region, but orphans
# hide (1) in a DIFFERENT region (a per-region tag/name sweep misses it), and (2) in a NICHE
# service — Athena work-groups — which agents almost never enumerate. The grader checks
# COMPLETENESS across BOTH regions + all services: anything with the prefix left = FAIL.
# NO TAGS (the prefix is in resource NAMES only) so the Resource Groups Tagging API cannot dump
# the inventory — the agent must enumerate each service/region itself. Cheap (all near-free,
# short-lived). Writes ground truth to ./seed_state.json (CWD = runspace root).
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
PRIMARY="$AWS_REGION"
if [[ "$PRIMARY" == "us-west-2" ]]; then SECONDARY="us-east-1"; else SECONDARY="us-west-2"; fi

RUN_ID="7c21"
PREFIX="aaq-${RUN_ID}"
WORKGROUP="${PREFIX}-wg"; SECRET="${PREFIX}-secret"
SSM_PARAM="/${PREFIX}/config"; QUEUE="${PREFIX}-queue"
W_WORKGROUP="${PREFIX}-wg"; W_PARAM="/${PREFIX}/west"

echo "==> setup ext_archit_decommission_analytics (account $ACCOUNT_ID, home $PRIMARY, prefix $PREFIX)"

# ── home region ($PRIMARY): obvious resources + niche orphans ──────────────────
aws athena create-work-group --name "$WORKGROUP" --region "$PRIMARY" >/dev/null

aws secretsmanager create-secret --name "$SECRET" --secret-string "decommission-me" \
  --region "$PRIMARY" >/dev/null

aws ssm put-parameter --name "$SSM_PARAM" --value "x" --type SecureString \
  --region "$PRIMARY" >/dev/null

QUEUE_URL="$(aws sqs create-queue --queue-name "$QUEUE" --region "$PRIMARY" --query 'QueueUrl' --output text)"

# ── SECONDARY region ($SECONDARY): the orphans in the "forgotten" region ────────
aws athena create-work-group --name "$W_WORKGROUP" --region "$SECONDARY" >/dev/null
aws ssm put-parameter --name "$W_PARAM" --value "x" --type SecureString \
  --region "$SECONDARY" >/dev/null

echo "  home($PRIMARY): workgroup=$WORKGROUP secret=$SECRET ssm=$SSM_PARAM queue=$QUEUE"
echo "  away($SECONDARY): workgroup=$W_WORKGROUP param=$W_PARAM"

python3 - "seed_state.json" <<PY
import json, sys
json.dump({
  "project": "${ACCOUNT_ID}", "account_id": "${ACCOUNT_ID}", "region": "${PRIMARY}",
  "prefix": "${PREFIX}", "run_id": "${RUN_ID}",
  "primary_region": "${PRIMARY}", "secondary_region": "${SECONDARY}",
  "home": {"workgroup": "${WORKGROUP}", "secret": "${SECRET}",
           "ssm_param": "${SSM_PARAM}", "queue_url": "${QUEUE_URL}"},
  "away": {"workgroup": "${W_WORKGROUP}", "ssm_param": "${W_PARAM}"},
}, open(sys.argv[1], "w"), indent=2)
print("  wrote", sys.argv[1])
PY
echo "==> setup complete — fully decommission '$PREFIX' (nothing left behind, anywhere)"
