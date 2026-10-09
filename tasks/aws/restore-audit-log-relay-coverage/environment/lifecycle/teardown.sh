#!/usr/bin/env bash
# Deletes the account-level subscription filter policies, /svc/ log groups,
# audit-relay-* streams and relay roles in both regions.
set -uo pipefail
# Log group names start with "/"; keep Git Bash from rewriting them as Windows paths.
export MSYS_NO_PATHCONV=1
REGION="${AWS_REGION:-us-east-1}"
for REGION in "$REGION" us-west-2; do
for p in $(aws logs describe-account-policies --policy-type SUBSCRIPTION_FILTER_POLICY \
             --region "$REGION" --query 'accountPolicies[].policyName' --output text 2>/dev/null); do
  aws logs delete-account-policy --policy-name "$p" --policy-type SUBSCRIPTION_FILTER_POLICY \
    --region "$REGION" >/dev/null 2>&1 || true
done
for g in $(aws logs describe-log-groups --log-group-name-prefix /svc/ --region "$REGION" \
             --query 'logGroups[].logGroupName' --output text 2>/dev/null); do
  aws logs delete-log-group --log-group-name "$g" --region "$REGION" >/dev/null 2>&1 || true
done
for s in $(aws kinesis list-streams --region "$REGION" --query 'StreamNames' --output text 2>/dev/null); do
  case "$s" in audit-relay-*) aws kinesis delete-stream --stream-name "$s" \
      --enforce-consumer-deletion --region "$REGION" >/dev/null 2>&1 || true ;; esac
done
for r in $(aws iam list-roles --query 'Roles[?starts_with(RoleName,`audit-relay-cwl-`)].RoleName' --output text 2>/dev/null); do
  for pol in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$pol" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
done
done
exit 0
