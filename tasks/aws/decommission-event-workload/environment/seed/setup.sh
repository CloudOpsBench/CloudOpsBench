#!/usr/bin/env bash
# ext_archit_decommission_events bundle setup — discovery-ceiling decommission (AWS).
# Hand-build a small event-driven stack via the CLI, every resource carrying the prefix
# `aeb-<region>`. The agent is told to FULLY decommission it (nothing left behind). The
# trap is the discovery ceiling: the obvious resources live in the home region, but
# orphans hide in a DIFFERENT region (a per-region name sweep misses them) — and one
# in-scope service is niche: EventBridge rules (`aws events list-rules`), which agents
# routinely skip. NO TAGS (the prefix is in resource NAMES only) so the agent cannot dump
# the inventory via the Resource Groups Tagging API — it must discover each resource
# itself, per-service and per-region. Writes ground truth to ./seed_state.json (CWD).
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
PRIMARY="$AWS_REGION"
if [[ "$PRIMARY" == "us-west-2" ]]; then SECONDARY="us-east-1"; else SECONDARY="us-west-2"; fi

PREFIX="aeb-${PRIMARY}"   # deterministic; the prompt references it as aeb-{region}
RULE="${PREFIX}-rule"; QUEUE="${PREFIX}-queue"; TOPIC="${PREFIX}-topic"
W_RULE="${PREFIX}-rule"; W_QUEUE="${PREFIX}-queue"

echo "==> setup ext_archit_decommission_events (home $PRIMARY, prefix $PREFIX)"

# ── home region ($PRIMARY): obvious resources + the niche EventBridge rule ──────
# Bare rule: no targets, so NO role is required. Disabled so it never fires.
aws events put-rule --name "$RULE" --schedule-expression "rate(1 day)" --state DISABLED \
  --region "$PRIMARY" >/dev/null
QUEUE_URL="$(aws sqs create-queue --queue-name "$QUEUE" --region "$PRIMARY" --query 'QueueUrl' --output text)"
aws sns create-topic --name "$TOPIC" --region "$PRIMARY" >/dev/null

# ── SECONDARY region ($SECONDARY): the orphans in the "forgotten" region ────────
# A cross-region EventBridge rule (bare) + an SQS queue — the dominant trap.
aws events put-rule --name "$W_RULE" --schedule-expression "rate(1 day)" --state DISABLED \
  --region "$SECONDARY" >/dev/null
W_QUEUE_URL="$(aws sqs create-queue --queue-name "$W_QUEUE" --region "$SECONDARY" --query 'QueueUrl' --output text)"

echo "  home($PRIMARY): rule=$RULE queue=$QUEUE topic=$TOPIC"
echo "  away($SECONDARY): rule=$W_RULE queue=$W_QUEUE"

python3 - <<PY
import json
json.dump({
  "prefix": "${PREFIX}",
  "primary_region": "${PRIMARY}", "secondary_region": "${SECONDARY}",
  "home": {"rule": "${RULE}", "queue_url": "${QUEUE_URL}", "topic": "${TOPIC}"},
  "away": {"rule": "${W_RULE}", "queue_url": "${W_QUEUE_URL}"},
}, open("seed_state.json", "w"), indent=2)
print("  wrote seed_state.json")
PY
echo "==> setup complete — fully decommission '$PREFIX' (nothing left behind, anywhere)"
