#!/usr/bin/env bash
set -euo pipefail
SM_NAME="batch-settlement"
ROLE_NAME="batch-settlement-sfn-role"
SM_ARN="$(aws stepfunctions list-state-machines --query "stateMachines[?name=='${SM_NAME}'].stateMachineArn | [0]" --output text 2>/dev/null || true)"
if [ -n "${SM_ARN:-}" ] && [ "$SM_ARN" != "None" ]; then
  for A in $(aws stepfunctions list-state-machine-aliases --state-machine-arn "$SM_ARN" --query "stateMachineAliases[].stateMachineAliasArn" --output text 2>/dev/null || true); do
    aws stepfunctions delete-state-machine-alias --state-machine-alias-arn "$A" 2>/dev/null || true
  done
  for V in $(aws stepfunctions list-state-machine-versions --state-machine-arn "$SM_ARN" --query "stateMachineVersions[].stateMachineVersionArn" --output text 2>/dev/null || true); do
    aws stepfunctions delete-state-machine-version --state-machine-version-arn "$V" 2>/dev/null || true
  done
  aws stepfunctions delete-state-machine --state-machine-arn "$SM_ARN" 2>/dev/null || true
fi
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
echo "teardown complete"
