#!/usr/bin/env bash
# Seeds a Lambda function with stable and candidate versions behind a weighted
# `live` alias, a CloudWatch error alarm, and a CodeDeploy application and
# deployment group with rollback and alarm monitoring disabled. Writes
# task_context.json.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TASK_SEED="${TASK_ID:-$(basename "$PWD")}:${ACCOUNT_ID}"
SUFFIX="$(printf '%s' "$TASK_SEED" | shasum | cut -c1-10)"
PREFIX="vera-canary-${SUFFIX}"
FUNCTION_NAME="${PREFIX}-function"
ALIAS_NAME="live"
APP_NAME="${PREFIX}-app"
GROUP_NAME="${PREFIX}-group"
ALARM_NAME="${PREFIX}-errors"
EXEC_ROLE="${PREFIX}-execution"
DEPLOY_ROLE="${PREFIX}-codedeploy"
TASK_TAG="vera-canary-${SUFFIX}"
OWNER="vera"
PROFILE="secure-canary-rollback-v1"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

retry() {
  local attempts="$1"; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then return 1; fi
    n=$((n + 1)); sleep 3
  done
}

function_is_active() {
  local state update
  state="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --query State --output text 2>/dev/null || true)"
  update="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --query LastUpdateStatus --output text 2>/dev/null || true)"
  [ "$state" = "Active" ] && [ "$update" = "Successful" ]
}

cat > "$TMP_DIR/lambda-trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
cat > "$TMP_DIR/deploy-trust.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codedeploy.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
cat > "$TMP_DIR/log-policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/lambda/${FUNCTION_NAME}:*"}]}
JSON

if ! aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document "file://$TMP_DIR/lambda-trust.json" \
    --tags Key=CloudOpTask,Value="$TASK_TAG" Key=Owner,Value="$OWNER" >/dev/null
  aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name FunctionLogs --policy-document "file://$TMP_DIR/log-policy.json"
fi
if ! aws iam get-role --role-name "$DEPLOY_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$DEPLOY_ROLE" --assume-role-policy-document "file://$TMP_DIR/deploy-trust.json" \
    --tags Key=CloudOpTask,Value="$TASK_TAG" Key=Owner,Value="$OWNER" >/dev/null
  retry 8 aws iam attach-role-policy --role-name "$DEPLOY_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSCodeDeployRoleForLambda
fi
EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query 'Role.Arn' --output text)"
DEPLOY_ROLE_ARN="$(aws iam get-role --role-name "$DEPLOY_ROLE" --query 'Role.Arn' --output text)"
EXEC_ROLE_ID="$(aws iam get-role --role-name "$EXEC_ROLE" --query 'Role.RoleId' --output text)"
DEPLOY_ROLE_ID="$(aws iam get-role --role-name "$DEPLOY_ROLE" --query 'Role.RoleId' --output text)"

printf '%s\n' 'def handler(event, context): return {"statusCode": 200, "body": "seeded"}' > "$TMP_DIR/index.py"
python3 - "$TMP_DIR/function.zip" "$TMP_DIR/index.py" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "index.py")
PY

if ! aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  # IAM trust relationships can take a short time to propagate to Lambda.
  retry 30 aws lambda create-function --function-name "$FUNCTION_NAME" --runtime python3.12 --role "$EXEC_ROLE_ARN" \
    --handler index.handler --timeout 15 --memory-size 128 --zip-file "fileb://$TMP_DIR/function.zip" \
    --description "Vera sentinel: ${PREFIX}" \
    --environment "Variables={TASK_SENTINEL=${PREFIX},DEPLOYMENT_MODE=seeded}" \
    --tags "CloudOpTask=${TASK_TAG},Owner=${OWNER}" >/dev/null 2>&1
fi
# A create call can return before Lambda accepts version publishing requests.
retry 30 function_is_active
VERSION_1="$(aws lambda publish-version --function-name "$FUNCTION_NAME" --description stable --query Version --output text)"
aws lambda update-function-configuration --function-name "$FUNCTION_NAME" \
  --environment "Variables={TASK_SENTINEL=${PREFIX},DEPLOYMENT_MODE=candidate}" >/dev/null
retry 30 function_is_active
VERSION_2="$(aws lambda publish-version --function-name "$FUNCTION_NAME" --description candidate --query Version --output text)"
FUNCTION_ARN="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --query FunctionArn --output text)"
CODE_SHA256="$(aws lambda get-function-configuration --function-name "$FUNCTION_NAME" --query CodeSha256 --output text)"

if aws lambda get-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" >/dev/null 2>&1; then
  aws lambda update-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$VERSION_2" \
    --routing-config "AdditionalVersionWeights={${VERSION_1}=0.5}" >/dev/null
else
  aws lambda create-alias --function-name "$FUNCTION_NAME" --name "$ALIAS_NAME" --function-version "$VERSION_2" \
    --routing-config "AdditionalVersionWeights={${VERSION_1}=0.5}" >/dev/null
fi
ALIAS_ARN="${FUNCTION_ARN}:${ALIAS_NAME}"

aws cloudwatch put-metric-alarm --alarm-name "$ALARM_NAME" --alarm-description "Vera sentinel ${PREFIX}" \
  --namespace AWS/Lambda --metric-name Errors --statistic Sum --period 300 --evaluation-periods 1 \
  --threshold 2 --comparison-operator GreaterThanThreshold --treat-missing-data breaching \
  --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" >/dev/null

aws deploy create-application --application-name "$APP_NAME" --compute-platform Lambda >/dev/null 2>&1 || true
if aws deploy get-deployment-group --application-name "$APP_NAME" --deployment-group-name "$GROUP_NAME" >/dev/null 2>&1; then
  aws deploy update-deployment-group --application-name "$APP_NAME" --current-deployment-group-name "$GROUP_NAME" \
    --deployment-config-name CodeDeployDefault.LambdaAllAtOnce --service-role-arn "$DEPLOY_ROLE_ARN" \
    --alarm-configuration "enabled=false,ignorePollAlarmFailure=false,alarms=[{name=${ALARM_NAME}}]" --auto-rollback-configuration "enabled=false" >/dev/null
else
  aws deploy create-deployment-group --application-name "$APP_NAME" --deployment-group-name "$GROUP_NAME" \
    --deployment-config-name CodeDeployDefault.LambdaAllAtOnce --service-role-arn "$DEPLOY_ROLE_ARN" \
    --deployment-style "deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL" \
    --auto-rollback-configuration "enabled=false" --alarm-configuration "enabled=false,ignorePollAlarmFailure=false,alarms=[{name=${ALARM_NAME}}]" \
    --tags Key=CloudOpTask,Value="$TASK_TAG" Key=Owner,Value="$OWNER" >/dev/null
fi
GROUP_ID="$(aws deploy get-deployment-group --application-name "$APP_NAME" --deployment-group-name "$GROUP_NAME" --query 'deploymentGroupInfo.deploymentGroupId' --output text)"
APPLICATION_ID="$(aws deploy get-application --application-name "$APP_NAME" --query 'application.applicationId' --output text)"

aws lambda tag-resource --resource "$FUNCTION_ARN" --tags "CloudOpTask=$TASK_TAG,Owner=$OWNER" >/dev/null
aws cloudwatch tag-resource --resource-arn "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:${ALARM_NAME}" --tags "Key=CloudOpTask,Value=$TASK_TAG" "Key=Owner,Value=$OWNER" >/dev/null || true

python3 - <<PY
import json, os
c={
 "region":"$REGION","account_id":"$ACCOUNT_ID","task_tag":"$TASK_TAG","owner":"$OWNER",
 "function_name":"$FUNCTION_NAME","function_arn":"$FUNCTION_ARN","code_sha256":"$CODE_SHA256","alias_name":"$ALIAS_NAME","alias_arn":"$ALIAS_ARN",
 "stable_version":"$VERSION_1","candidate_version":"$VERSION_2","execution_role_name":"$EXEC_ROLE","execution_role_arn":"$EXEC_ROLE_ARN","execution_role_id":"$EXEC_ROLE_ID",
 "deploy_role_name":"$DEPLOY_ROLE","deploy_role_arn":"$DEPLOY_ROLE_ARN","deploy_role_id":"$DEPLOY_ROLE_ID","application_name":"$APP_NAME","application_id":"$APPLICATION_ID","deployment_group_name":"$GROUP_NAME","deployment_group_id":"$GROUP_ID",
 "alarm_name":"$ALARM_NAME","sentinel":"$PREFIX","function_configuration": {
   "Runtime":"python3.12","Handler":"index.handler","Timeout":15,"MemorySize":128,
   "Description":"Vera sentinel: $PREFIX","Environment":{"Variables":{"TASK_SENTINEL":"$PREFIX","DEPLOYMENT_MODE":"candidate"}}
 }
}
for p in ["task_context.json", os.path.join(os.environ.get("AGENT_WORKSPACE","."),"task_context.json")]:
 os.makedirs(os.path.dirname(p) or ".",exist_ok=True)
 with open(p,"w") as f: json.dump(c,f,indent=2)
PY

echo "Seeded ${FUNCTION_NAME}; stable=${VERSION_1}; candidate=${VERSION_2}"
