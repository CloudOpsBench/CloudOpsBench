#!/usr/bin/env bash
# Golden solution for aws_task12 (deterministic, no model).
# 1. terraform apply — index.py is now the NEW build (setup swapped it), so this
#    publishes a new version and advances the `live` alias to it.
# 2. Reverse-look-up the hidden SQS event-source mapping (pinned to the OLD
#    numbered version) and repoint it at the promoted `live` alias so it tracks
#    the new code (otherwise the promote alone leaves it on stale code).
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SFX="$AWS_REGION"
WS="workspaces/aws_task12"
FUNC="vera-order-processor-${SFX}"
[ -d "$WS" ] || { echo "workspace $WS missing — run --setup first" >&2; exit 1; }

terraform -chdir="$WS" init -input=false -no-color >/dev/null
terraform -chdir="$WS" apply -auto-approve -input=false -no-color >/dev/null

LIVE_ARN=$(aws lambda get-alias --function-name "$FUNC" --name live --query AliasArn --output text)
UUID=$(aws lambda list-event-source-mappings \
  --query "EventSourceMappings[?contains(FunctionArn, '${FUNC}')].UUID | [0]" --output text)
aws lambda update-event-source-mapping --uuid "$UUID" --function-name "$LIVE_ARN" >/dev/null

for _ in $(seq 1 60); do
  st=$(aws lambda get-event-source-mapping --uuid "$UUID" --query 'State' --output text 2>/dev/null || echo Updating)
  [ "$st" = "Enabled" ] && break
  sleep 2
done
echo "==> Solution applied: new version promoted onto live, hidden ESM repointed to the alias"
