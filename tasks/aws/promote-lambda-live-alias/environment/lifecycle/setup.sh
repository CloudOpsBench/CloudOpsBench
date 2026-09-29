#!/usr/bin/env bash
# Deploys a Lambda with a `live` alias via Terraform, then creates an SQS
# event-source mapping outside Terraform that is pinned to the current numbered
# version rather than the alias. The old CodeSha256 is stored in SSM at
# /vera/<func>/old-sha for the checker.
set -euo pipefail

AWS_REGION="${AWS_REGION:?AWS_REGION required}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SFX="$AWS_REGION"
WS="${AGENT_WORKSPACE:?platform must set AGENT_WORKSPACE}"
FUNC="vera-order-processor-${SFX}"; QNAME="vera-order-events-${SFX}"

echo "==> Setting up Lambda, live alias, and version-pinned SQS mapping"
rm -rf "$WS"; mkdir -p "$WS"

cat > "${WS}/provider.tf" <<EOF
terraform {
  required_providers {
    aws     = { source = "hashicorp/aws" }
    archive = { source = "hashicorp/archive" }
  }
}
provider "aws" {
  region = "${AWS_REGION}"
}
EOF

cat > "${WS}/main.tf" <<'EOF'
data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

locals {
  acct    = data.aws_caller_identity.me.account_id
  sfx     = data.aws_region.current.name
  fn_name = "vera-order-processor-${local.sfx}"
}

resource "aws_iam_role" "exec" {
  name = "vera-order-processor-exec-${local.sfx}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "exec" {
  name = "exec"
  role = aws_iam_role.exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "*" },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = "*" }
    ]
  })
}

data "archive_file" "code" {
  type        = "zip"
  output_path = "${path.module}/function.zip"
  source {
    content  = file("${path.module}/index.py")
    filename = "index.py"
  }
}

resource "aws_lambda_function" "order_processor" {
  function_name    = local.fn_name
  role             = aws_iam_role.exec.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  publish          = true
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.order_processor.function_name
  function_version = aws_lambda_function.order_processor.version
}
EOF

cat > "${WS}/index.py" <<'EOF'
def handler(event, context):
    return {"version": "old"}
EOF

terraform -chdir="$WS" init -input=false -no-color >/dev/null
terraform -chdir="$WS" apply -auto-approve -input=false -no-color >/dev/null
echo "  Applied Terraform: ${FUNC} and live alias"

# SQS queue and event-source mapping pinned to the numbered version, outside Terraform.
QURL=""
for _ in $(seq 1 40); do
  if QURL=$(aws sqs create-queue --queue-name "$QNAME" --query QueueUrl --output text 2>/dev/null); then break; fi
  sleep 3
done
[ -n "$QURL" ] || { echo "could not create queue $QNAME" >&2; exit 1; }
QARN=$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

OLD_VER=$(aws lambda get-alias --function-name "$FUNC" --name live --query FunctionVersion --output text)
FN_OLD="arn:aws:lambda:${SFX}:${ACCOUNT_ID}:function:${FUNC}:${OLD_VER}"
OLD_SHA=""
for _ in $(seq 1 60); do
  OLD_SHA=$(aws lambda get-function --function-name "$FN_OLD" --query 'Configuration.CodeSha256' --output text 2>/dev/null || echo "")
  [ -n "$OLD_SHA" ] && [ "$OLD_SHA" != "None" ] && break
  sleep 2
done
[ -n "$OLD_SHA" ] && [ "$OLD_SHA" != "None" ] || { echo "version $OLD_VER did not resolve" >&2; exit 1; }
aws ssm put-parameter --name "/vera/${FUNC}/old-sha" --type String --value "$OLD_SHA" --overwrite >/dev/null

for _ in $(seq 1 30); do
  if aws lambda create-event-source-mapping --function-name "$FN_OLD" --event-source-arn "$QARN" --batch-size 10 >/dev/null 2>&1; then break; fi
  sleep 2
done
for _ in $(seq 1 60); do
  st=$(aws lambda list-event-source-mappings --function-name "${FUNC}:${OLD_VER}" --query 'EventSourceMappings[0].State' --output text 2>/dev/null || echo Creating)
  [ "$st" = "Enabled" ] && break
  sleep 2
done
echo "  Created SQS event-source mapping pinned to ${FUNC}:${OLD_VER}"

# Replace the handler with the new build that the task asks to roll out.
cat > "${WS}/index.py" <<'EOF'
def handler(event, context):
    return {"version": "new"}
EOF

echo "==> Setup complete"

# Private runtime metadata for the portal; do not copy into the agent workspace.
python3 - <<'PORTAL_STATE'
import json, os
json.dump({"region": os.environ["AWS_REGION"]}, open("seed_state.json", "w"), indent=2)
PORTAL_STATE
