#!/usr/bin/env bash
set -uo pipefail
export AWS_PAGER=""

STATE_FILE=""
[ -f seed_state.json ] && STATE_FILE="seed_state.json"
[ -z "$STATE_FILE" ] && [ -f cleanup_state.json ] && STATE_FILE="cleanup_state.json"
if [ -n "$STATE_FILE" ]; then
  readarray -t V < <(python3 - "$STATE_FILE" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
for k in ['event_source_mapping_uuid','function_name','role_name','role_policy_name','source_table','processed_table','receipt_table','bucket']:
    print(s.get(k,''))
PY
)
  ESM_UUID="${V[0]}"; FUNCTION_NAME="${V[1]}"; ROLE_NAME="${V[2]}"; POLICY_NAME="${V[3]}"; SOURCE_TABLE="${V[4]}"; PROCESSED_TABLE="${V[5]}"; RECEIPT_TABLE="${V[6]}"; BUCKET="${V[7]}"
  [ -n "$ESM_UUID" ] && aws lambda delete-event-source-mapping --uuid "$ESM_UUID" >/dev/null 2>&1 || true
  [ -n "$FUNCTION_NAME" ] && aws lambda delete-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1 || true
  [ -n "$ROLE_NAME" ] && [ -n "$POLICY_NAME" ] && aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" >/dev/null 2>&1 || true
  [ -n "$ROLE_NAME" ] && aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
  [ -n "$SOURCE_TABLE" ] && aws dynamodb delete-table --table-name "$SOURCE_TABLE" >/dev/null 2>&1 || true
  [ -n "$PROCESSED_TABLE" ] && aws dynamodb delete-table --table-name "$PROCESSED_TABLE" >/dev/null 2>&1 || true
  [ -n "$RECEIPT_TABLE" ] && aws dynamodb delete-table --table-name "$RECEIPT_TABLE" >/dev/null 2>&1 || true
  if [ -n "$BUCKET" ]; then
    aws s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$BUCKET" >/dev/null 2>&1 || true
  fi
fi
rm -f seed_state.json cleanup_state.json
