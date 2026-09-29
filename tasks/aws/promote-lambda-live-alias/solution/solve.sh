#!/usr/bin/env bash
# Apply Terraform to publish the new build and move the `live` alias, then
# repoint the SQS event-source mapping from the old numbered version to the alias.
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SFX="$AWS_REGION"
WS="${AGENT_WORKSPACE:?platform must set AGENT_WORKSPACE}"
FUNC="vera-order-processor-${SFX}"
[ -d "$WS" ] || { echo "workspace $WS missing" >&2; exit 1; }

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
echo "==> Promoted live alias and repointed the event-source mapping"
