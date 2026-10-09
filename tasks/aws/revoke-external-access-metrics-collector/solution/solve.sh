#!/usr/bin/env bash
# Replaces the policy of every vera2-* SNS topic that allows principal "*" with an
# account-only policy, and clears the sharing policy of every vera2-* Serverless
# Application Repository application that allows principal "*".
set -uo pipefail
zone="us-east-1"
me=$(aws sts get-caller-identity --query Account --output text)

for t in $(aws sns list-topics --region "$zone" --query 'Topics[].TopicArn' --output text | tr '\t' '\n' | grep ':vera2-' || true); do
  doc=$(aws sns get-topic-attributes --topic-arn "$t" --region "$zone" --query 'Attributes.Policy' --output text 2>/dev/null)
  case "$doc" in
    *'"*"'*)
      locked="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Owner\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$me\"},\"Action\":\"SNS:Publish\",\"Resource\":\"$t\"}]}"
      aws sns set-topic-attributes --topic-arn "$t" --attribute-name Policy --region "$zone" --attribute-value "$locked" 2>/dev/null || true ;;
  esac
done

for a in $(aws serverlessrepo list-applications --region "$zone" --query "Applications[?starts_with(Name,'vera2-')].ApplicationId" --output text | tr '\t' '\n'); do
  [ -n "$a" ] || continue
  doc=$(aws serverlessrepo get-application-policy --application-id "$a" --region "$zone" --query 'Statements' --output json 2>/dev/null)
  case "$doc" in
    *'"*"'*)
      aws serverlessrepo put-application-policy --application-id "$a" --statements '[]' --region "$zone" >/dev/null 2>&1 || true ;;
  esac
done
echo "stripped public sharing from vera2 SNS topics and SAR applications"
