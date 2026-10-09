#!/usr/bin/env bash
# teardown.sh — courtesy cleanup
set -euo pipefail

if [ -f seed_state.json ]; then
  DATA_BUCKET=$(python3 -c "import json;print(json.load(open('seed_state.json'))['data_bucket'])")
  ARCHIVE_BUCKET=$(python3 -c "import json;print(json.load(open('seed_state.json'))['archive_bucket'])")
  APP_ROLE=$(python3 -c "import json;print(json.load(open('seed_state.json'))['app_role'])")
  BOUNDARY_ARN=$(python3 -c "import json;print(json.load(open('seed_state.json'))['boundary_arn'])")
  KEY_ID=$(python3 -c "import json;print(json.load(open('seed_state.json'))['key_id'])")

  for B in "${DATA_BUCKET}" "${ARCHIVE_BUCKET}"; do
    aws s3 rm "s3://${B}" --recursive || true
    aws s3api delete-bucket --bucket "${B}" || true
  done

  for PNAME in $(aws iam list-role-policies --role-name "${APP_ROLE}" --query 'PolicyNames' --output text 2>/dev/null || echo ""); do
    aws iam delete-role-policy --role-name "${APP_ROLE}" --policy-name "${PNAME}" || true
  done
  aws iam delete-role --role-name "${APP_ROLE}" || true

  # delete non-default boundary policy versions, then the policy
  for V in $(aws iam list-policy-versions --policy-arn "${BOUNDARY_ARN}" \
      --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text 2>/dev/null || echo ""); do
    aws iam delete-policy-version --policy-arn "${BOUNDARY_ARN}" --version-id "${V}" || true
  done
  aws iam delete-policy --policy-arn "${BOUNDARY_ARN}" || true

  aws kms schedule-key-deletion --key-id "${KEY_ID}" --pending-window-in-days 7 || true
fi

echo "Teardown complete."
