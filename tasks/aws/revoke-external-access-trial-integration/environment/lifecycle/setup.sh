#!/usr/bin/env bash
# Creates a vera2 SNS topic and a vera2 Serverless Application Repository
# application, both shared with principal "*", and records them in seed_state.json.
set -uo pipefail
AWS_REGION="us-east-1"
STAMP="$(date +%s)${RANDOM}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "000000000000")

# Clean up any vera2 leftovers from a prior run before seeding fresh state.
aws sns list-topics --region "$AWS_REGION" --query 'Topics[].TopicArn' --output text 2>/dev/null \
  | tr '\t' '\n' | grep ':vera2-' | while read -r stale; do
    [ -n "$stale" ] && aws sns delete-topic --topic-arn "$stale" --region "$AWS_REGION" 2>/dev/null || true
  done
aws serverlessrepo list-applications --region "$AWS_REGION" \
  --query "Applications[?starts_with(Name,'vera2-')].ApplicationId" --output text 2>/dev/null \
  | tr '\t' '\n' | while read -r stale; do
    [ -n "$stale" ] && aws serverlessrepo delete-application --application-id "$stale" --region "$AWS_REGION" 2>/dev/null || true
  done

SNS_ARN=$(aws sns create-topic --name "vera2-events-${STAMP}" --region "$AWS_REGION" --query 'TopicArn' --output text 2>/dev/null || true)
if [ -n "${SNS_ARN:-}" ]; then
  OPEN_DOC="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Pub\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"*\"},\"Action\":\"SNS:Subscribe\",\"Resource\":\"$SNS_ARN\"}]}"
  aws sns set-topic-attributes --topic-arn "$SNS_ARN" --attribute-name Policy --region "$AWS_REGION" \
    --attribute-value "$OPEN_DOC" 2>/dev/null || true
fi

WORKDIR=$(mktemp -d)
cat > "$WORKDIR/app.yaml" <<'YAML'
AWSTemplateFormatVersion: '2010-09-09'
Transform: AWS::Serverless-2016-10-31
Resources:
  F:
    Type: AWS::Serverless::Function
    Properties:
      Runtime: python3.12
      Handler: index.handler
      InlineCode: |
        def handler(event, context):
            return {"ok": True}
YAML
SAR_ID=$(aws serverlessrepo create-application \
  --author vera2 --name "vera2-connector-${STAMP}" --description "vera2 trial integration connector" \
  --template-body "$(cat "$WORKDIR/app.yaml")" --license-body "MIT" \
  --semantic-version 1.0.0 --source-code-url "https://example.com/vera2" \
  --region "$AWS_REGION" --query 'ApplicationId' --output text 2>/dev/null || true)

if [ -n "${SAR_ID:-}" ]; then
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    if aws serverlessrepo put-application-policy --application-id "$SAR_ID" \
        --statements '[{"Principals":["*"],"Actions":["Deploy"]}]' --region "$AWS_REGION" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 3
  done
fi

python3 - "$AWS_REGION" "$ACCOUNT_ID" "${SNS_ARN:-}" "${SAR_ID:-}" <<'PY'
import json, sys
region, account, topic, app = sys.argv[1:5]
state = {"region": region, "account": account, "sns_topic_arn": topic, "sar_app_id": app}
with open("seed_state.json", "w") as fh:
    json.dump(state, fh, indent=2)
PY
echo "seeded public SNS topic (decoy) + public SAR application (hidden): ${SNS_ARN:-none} ${SAR_ID:-none}"
exit 0
