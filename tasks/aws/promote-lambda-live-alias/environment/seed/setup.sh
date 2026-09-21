#!/usr/bin/env bash
# aws_task12 bundle setup — port of agent-harness realaws/r9/rl_lambda_alias_promote_strands_esm.
# "Promote/prune strands a version-pinned consumer." A Lambda is rolled out by
# publishing a new version and moving the `live` alias. The trap: a hidden SQS
# event-source mapping (ESM) is pinned to a SPECIFIC numbered version (the OLD
# code), NOT the alias — so promoting the alias leaves the ESM invoking stale code.
# The ESM is out-of-band (not in main.tf); discoverable only by reverse-lookup
# (lambda list-event-source-mappings -> its FunctionArn qualifier). Correct fix
# promotes the alias AND repoints the ESM at the promoted alias/new version.
# Ground truth (old CodeSha256) is recorded in SSM at /vera/<func>/old-sha.
#
# NOTE: the agent-harness exec role carries a vera-sandbox-boundary permissions
# boundary that does not exist in this sandbox, so it is omitted (a rail, not the
# mechanism).
set -euo pipefail

AWS_REGION="${AWS_REGION:?AWS_REGION required}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SFX="$AWS_REGION"
WS="workspaces/aws_task12"
FUNC="vera-order-processor-${SFX}"; QNAME="vera-order-events-${SFX}"

echo "==> aws_task12 setup: Lambda + live alias + hidden version-pinned ESM"
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

# OLD handler — the currently-live build.
cat > "${WS}/index.py" <<'EOF'
def handler(event, context):
    # OLD order-processing handler (the currently-live build).
    return {"version": "old"}
EOF

terraform -chdir="$WS" init -input=false -no-color >/dev/null
terraform -chdir="$WS" apply -auto-approve -input=false -no-color >/dev/null
echo "  Terraform manages: ${FUNC} (old code published) + live alias"

# --- Out-of-band: SQS queue + an ESM pinned to the numbered OLD version ------
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
echo "  Out-of-band: SQS ESM pinned to ${FUNC}:${OLD_VER} (hidden; not in terraform)"

# Swap index.py to the NEW build — "the new handler is in index.py", ready to roll out.
cat > "${WS}/index.py" <<'EOF'
def handler(event, context):
    # NEW order-processing handler being rolled out.
    return {"version": "new"}
EOF
echo "  Swapped workspace index.py to the new build (pending rollout)"

echo ""
echo "==> aws_task12 setup complete"
echo "    Agent task: publish the new code and cut the live alias to it — without"
echo "    leaving anything that consumes this function stranded on the old version."
