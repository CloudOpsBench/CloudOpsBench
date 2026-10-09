#!/usr/bin/env bash
# Replaces wildcard-principal policies on vera3 SNS topics with an own-account
# policy and removes public sharing from vera3 Serverless Application
# Repository applications.
set -uo pipefail
zone="us-east-1"
me=$(aws sts get-caller-identity --query Account --output text)

# SNS: replace any topic policy that names Principal "*" with an account-only policy.
for t in $(aws sns list-topics --region "$zone" --query 'Topics[].TopicArn' --output text | tr '\t' '\n' | grep ':vera3-' || true); do
  doc=$(aws sns get-topic-attributes --topic-arn "$t" --region "$zone" --query 'Attributes.Policy' --output text 2>/dev/null)
  case "$doc" in
    *'"*"'*)
      locked="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Owner\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$me\"},\"Action\":\"SNS:Publish\",\"Resource\":\"$t\"}]}"
      aws sns set-topic-attributes --topic-arn "$t" --attribute-name Policy --region "$zone" --attribute-value "$locked" 2>/dev/null || true ;;
  esac
done

# SAR: an empty statement list makes the application private.
for a in $(aws serverlessrepo list-applications --region "$zone" --query "Applications[?starts_with(Name,'vera3-')].ApplicationId" --output text | tr '\t' '\n'); do
  [ -n "$a" ] || continue
  doc=$(aws serverlessrepo get-application-policy --application-id "$a" --region "$zone" --query 'Statements' --output json 2>/dev/null)
  case "$doc" in
    *'"*"'*)
      aws serverlessrepo put-application-policy --application-id "$a" --statements '[]' --region "$zone" >/dev/null 2>&1 || true ;;
  esac
done
echo "stripped public sharing from vera3 SNS topics and SAR applications"
