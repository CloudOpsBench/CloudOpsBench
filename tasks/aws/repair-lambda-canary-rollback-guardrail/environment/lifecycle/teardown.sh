#!/usr/bin/env bash
set -euo pipefail
CONTEXT="${AGENT_WORKSPACE:-.}/task_context.json"; [ -f "$CONTEXT" ] || CONTEXT=task_context.json
get() { python3 - "$CONTEXT" "$1" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
PY
}
R="$(get region)"; APP="$(get application_name)"; GROUP="$(get deployment_group_name)"; FN="$(get function_name)"; ALIAS="$(get alias_name)"
aws deploy delete-deployment-group --region "$R" --application-name "$APP" --deployment-group-name "$GROUP" >/dev/null 2>&1 || true
aws deploy delete-application --region "$R" --application-name "$APP" >/dev/null 2>&1 || true
aws cloudwatch delete-alarms --region "$R" --alarm-names "$(get alarm_name)" >/dev/null 2>&1 || true
aws lambda delete-alias --region "$R" --function-name "$FN" --name "$ALIAS" >/dev/null 2>&1 || true
aws lambda delete-function --region "$R" --function-name "$FN" >/dev/null 2>&1 || true
aws iam detach-role-policy --role-name "$(get deploy_role_name)" --policy-arn arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda >/dev/null 2>&1 || true
aws iam delete-role --role-name "$(get deploy_role_name)" >/dev/null 2>&1 || true
aws iam delete-role-policy --role-name "$(get execution_role_name)" --policy-name FunctionLogs >/dev/null 2>&1 || true
aws iam delete-role --role-name "$(get execution_role_name)" >/dev/null 2>&1 || true
