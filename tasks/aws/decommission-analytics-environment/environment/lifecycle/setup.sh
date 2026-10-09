#!/usr/bin/env bash
# Creates the `aaq-7c21` analytics stack with the CLI: an Athena work-group, a secret, an
# SSM parameter and an SQS queue in the home region, plus an Athena work-group and an SSM
# parameter in a second region. Resources carry the prefix in their names and have no
# tags. Writes the resource names to ./seed_state.json.
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

echo "==> setup decommission-analytics-environment (account $ACCOUNT_ID, home $PRIMARY, prefix $PREFIX)"

# Home region.
aws athena create-work-group --name "$WORKGROUP" --region "$PRIMARY" >/dev/null

aws secretsmanager create-secret --name "$SECRET" --secret-string "decommission-me" \
  --region "$PRIMARY" >/dev/null

aws ssm put-parameter --name "$SSM_PARAM" --value "x" --type SecureString \
  --region "$PRIMARY" >/dev/null

QUEUE_URL="$(aws sqs create-queue --queue-name "$QUEUE" --region "$PRIMARY" --query 'QueueUrl' --output text)"

# Second region.
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
