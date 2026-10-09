#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
for P in $(aws ssm get-parameters-by-path --path /vera2/ --recursive --region "$REGION" \
    --query "Parameters[].Name" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true); do
  aws ssm delete-parameter --name "$P" --region "$REGION" 2>/dev/null || true
done
echo "torn down vera2 ssm parameters"
