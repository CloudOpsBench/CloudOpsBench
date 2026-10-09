#!/usr/bin/env bash
set -euo pipefail
CONTEXT="${AGENT_WORKSPACE:-.}/task_context.json"
[ -f "$CONTEXT" ] || CONTEXT=task_context.json
read_ctx() { python3 - "$CONTEXT" "$1" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
PY
}
REGION="$(read_ctx region)"; FUNCTION="$(read_ctx function_name)"; ALIAS="$(read_ctx alias_name)"
STABLE="$(read_ctx stable_version)"; APP="$(read_ctx application_name)"; GROUP="$(read_ctx deployment_group_name)"
ALARM="$(read_ctx alarm_name)"; DEPLOY_ROLE="$(read_ctx deploy_role_arn)"; ACCOUNT="$(read_ctx account_id)"
DEPLOY_ROLE_NAME="$(read_ctx deploy_role_name)"; TASK_TAG="$(read_ctx task_tag)"; OWNER="$(read_ctx owner)"; PROFILE=secure-canary-rollback-v1

cat > /tmp/codedeploy-trust-$$.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codedeploy.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
trap 'rm -f /tmp/codedeploy-trust-$$.json' EXIT
aws iam update-assume-role-policy --role-name "$DEPLOY_ROLE_NAME" --policy-document "file:///tmp/codedeploy-trust-$$.json"
for policy_arn in $(aws iam list-attached-role-policies --role-name "$DEPLOY_ROLE_NAME" --query 'AttachedPolicies[].PolicyArn' --output text); do
  [ "$policy_arn" = "None" ] && continue
  aws iam detach-role-policy --role-name "$DEPLOY_ROLE_NAME" --policy-arn "$policy_arn"
done
for policy_name in $(aws iam list-role-policies --role-name "$DEPLOY_ROLE_NAME" --query 'PolicyNames[]' --output text); do
  [ "$policy_name" = "None" ] && continue
  aws iam delete-role-policy --role-name "$DEPLOY_ROLE_NAME" --policy-name "$policy_name"
done
ALIAS_ARN="$(read_ctx alias_arn)"
cat > /tmp/codedeploy-policy-$$.json <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["lambda:GetAlias","lambda:UpdateAlias"],"Resource":"${ALIAS_ARN}"},
  {"Effect":"Allow","Action":"cloudwatch:DescribeAlarms","Resource":"*"}
]}
JSON
trap 'rm -f /tmp/codedeploy-trust-$$.json /tmp/codedeploy-policy-$$.json' EXIT
aws iam put-role-policy --role-name "$DEPLOY_ROLE_NAME" --policy-name SecureCanaryDeployment --policy-document "file:///tmp/codedeploy-policy-$$.json"

aws lambda update-alias --region "$REGION" --function-name "$FUNCTION" --name "$ALIAS" --function-version "$STABLE" --routing-config '{}' >/dev/null
aws cloudwatch put-metric-alarm --region "$REGION" --alarm-name "$ALARM" \
  --namespace AWS/Lambda --metric-name Errors --statistic Sum --period 60 --evaluation-periods 1 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold --treat-missing-data notBreaching \
  --dimensions "Name=FunctionName,Value=${FUNCTION}" "Name=Resource,Value=${FUNCTION}:${ALIAS}" >/dev/null
aws deploy update-deployment-group --region "$REGION" --application-name "$APP" --current-deployment-group-name "$GROUP" \
  --deployment-config-name CodeDeployDefault.LambdaCanary10Percent5Minutes --service-role-arn "$DEPLOY_ROLE" \
  --deployment-style "deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL" \
  --auto-rollback-configuration "enabled=true,events=DEPLOYMENT_FAILURE,DEPLOYMENT_STOP_ON_ALARM" \
  --alarm-configuration "enabled=true,ignorePollAlarmFailure=false,alarms=[{name=${ALARM}}]" >/dev/null
aws lambda tag-resource --region "$REGION" --resource "$(read_ctx function_arn)" --tags "CloudOpTask=$TASK_TAG,Owner=$OWNER,SecurityProfile=$PROFILE" >/dev/null
aws iam tag-role --role-name "$DEPLOY_ROLE_NAME" --tags Key=CloudOpTask,Value="$TASK_TAG" Key=Owner,Value="$OWNER" Key=SecurityProfile,Value="$PROFILE"
aws cloudwatch tag-resource --region "$REGION" --resource-arn "arn:aws:cloudwatch:${REGION}:${ACCOUNT}:alarm:${ALARM}" --tags "Key=CloudOpTask,Value=$TASK_TAG" "Key=Owner,Value=$OWNER" "Key=SecurityProfile,Value=$PROFILE" >/dev/null || true
