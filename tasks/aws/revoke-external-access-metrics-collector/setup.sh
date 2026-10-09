#!/usr/bin/env bash
set -uo pipefail
zone="us-east-1"
stamp="$(date +%s)${RANDOM}"
who=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "000000000000")

# --- scrub leftovers from earlier runs so a rerun starts clean ---
for old in $(aws sns list-topics --region "$zone" --query 'Topics[].TopicArn' --output text 2>/dev/null | tr '\t' '\n' | grep ':vera2-' || true); do
  aws sns delete-topic --topic-arn "$old" --region "$zone" 2>/dev/null || true
done
for old in $(aws serverlessrepo list-applications --region "$zone" --query "Applications[?starts_with(Name,'vera2-')].ApplicationId" --output text 2>/dev/null | tr '\t' '\n'); do
  aws serverlessrepo delete-application --application-id "$old" --region "$zone" 2>/dev/null || true
done

bus=$(aws sns create-topic --name "vera2-signals-${stamp}" --region "$zone" --query 'TopicArn' --output text 2>/dev/null || true)
if [ -n "${bus:-}" ]; then
  open_doc="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Pub\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"*\"},\"Action\":\"SNS:Subscribe\",\"Resource\":\"$bus\"}]}"
  aws sns set-topic-attributes --topic-arn "$bus" --attribute-name Policy --region "$zone" --attribute-value "$open_doc" 2>/dev/null || true
fi

work=$(mktemp -d)
tpl="$work/app.yaml"
cat > "$tpl" <<'YAML'
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
app=$(aws serverlessrepo create-application \
  --author vera2 --name "vera2-bridge-${stamp}" --description "vera2 analytics pilot bridge" \
  --template-body "$(cat "$tpl")" --license-body "MIT" \
  --semantic-version 1.0.0 --source-code-url "https://example.com/vera2" \
  --region "$zone" --query 'ApplicationId' --output text 2>/dev/null || true)

if [ -n "${app:-}" ]; then
  # version 1.0.0 registers on create, but flipping the app public needs that version fully registered, which
  # can trail the create call by a moment, so keep retrying until the policy sticks.
  tries=0
  while [ "$tries" -lt 20 ]; do
    if aws serverlessrepo put-application-policy --application-id "$app" \
        --statements '[{"Principals":["*"],"Actions":["Deploy"]}]' --region "$zone" >/dev/null 2>&1; then
      break
    fi
    tries=$((tries+1))
    sleep 3
  done
fi

python3 - "$zone" "$who" "${bus:-}" "${app:-}" <<'PY'
import json,sys
zone,acct,topic,appid=sys.argv[1:5]
json.dump({"region":zone,"account":acct,"sns_topic_arn":topic,"sar_app_id":appid},open("seed_state.json","w"),indent=2)
PY
echo "seeded decoy public SNS topic + hidden public SAR app: ${bus:-none} ${app:-none}"
exit 0
