#!/usr/bin/env bash
set -uo pipefail
AWS_REGION="us-east-1"
SELF=$(aws sts get-caller-identity --query Account --output text)

# SAR (hidden surface): any vera2 application whose sharing policy names "*" gets its statements emptied,
# which returns the application to private.
aws serverlessrepo list-applications --region "$AWS_REGION" \
  --query "Applications[?starts_with(Name,'vera2-')].ApplicationId" --output text \
  | tr '\t' '\n' | while read -r app_id; do
    [ -z "$app_id" ] && continue
    shared=$(aws serverlessrepo get-application-policy --application-id "$app_id" --region "$AWS_REGION" --query 'Statements' --output json 2>/dev/null)
    case "$shared" in
      *'"*"'*)
        aws serverlessrepo put-application-policy --application-id "$app_id" --statements '[]' --region "$AWS_REGION" >/dev/null 2>&1 || true ;;
    esac
  done

# SNS (obvious surface): any vera2 topic whose policy grants Principal "*" is rewritten to an account-only policy.
aws sns list-topics --region "$AWS_REGION" --query 'Topics[].TopicArn' --output text \
  | tr '\t' '\n' | grep ':vera2-' | while read -r topic_arn; do
    [ -z "$topic_arn" ] && continue
    current=$(aws sns get-topic-attributes --topic-arn "$topic_arn" --region "$AWS_REGION" --query 'Attributes.Policy' --output text 2>/dev/null)
    case "$current" in
      *'"*"'*)
        LOCKED="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Owner\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$SELF\"},\"Action\":\"SNS:Publish\",\"Resource\":\"$topic_arn\"}]}"
        aws sns set-topic-attributes --topic-arn "$topic_arn" --attribute-name Policy --region "$AWS_REGION" \
          --attribute-value "$LOCKED" 2>/dev/null || true ;;
    esac
  done

echo "stripped public sharing from vera2 SAR applications and SNS topics"
