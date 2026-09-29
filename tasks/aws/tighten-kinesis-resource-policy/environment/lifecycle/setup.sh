#!/usr/bin/env bash
# Terraform manages the events stream, an account-wide resource policy, and the
# producer, analytics consumer, and outsider roles (no Kinesis identity permissions).
# An enhanced-fan-out consumer is registered outside Terraform and relies on the
# resource policy for read access.
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SFX="$AWS_REGION"
WS="${AGENT_WORKSPACE:?platform must set AGENT_WORKSPACE}"
STREAM="vera-events-stream-${SFX}"
CONSUMER="vera-analytics-consumer-${SFX}"

echo "==> Setting up Kinesis stream and stream consumer (account $ACCOUNT_ID, region $AWS_REGION)"
rm -rf "$WS"; mkdir -p "$WS"

cat > "${WS}/provider.tf" <<EOF
terraform {
  required_providers { aws = { source = "hashicorp/aws" } }
}
provider "aws" {
  region = "${AWS_REGION}"
}
EOF

cat > "${WS}/main.tf" <<'EOF'
data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

locals {
  acct = data.aws_caller_identity.me.account_id
  sfx  = data.aws_region.current.name
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.acct]
    }
  }
}

resource "aws_iam_role" "producer" {
  name               = "vera-events-producer-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role" "consumer" {
  name               = "vera-analytics-consumer-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role" "outsider" {
  name               = "vera-outsider-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_kinesis_stream" "events" {
  name             = "vera-events-stream-${local.sfx}"
  shard_count      = 1
  retention_period = 24
}

resource "aws_kinesis_resource_policy" "events" {
  resource_arn = aws_kinesis_stream.events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAll"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.acct}:root" }
        Action = [
          "kinesis:PutRecord",
          "kinesis:PutRecords",
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:ListShards"
        ]
        Resource = aws_kinesis_stream.events.arn
      }
    ]
  })
}
EOF

terraform -chdir="$WS" init -input=false -no-color >/dev/null
terraform -chdir="$WS" apply -auto-approve -input=false -no-color >/dev/null
echo "  Applied Terraform: ${STREAM} and IAM roles"

# register-stream-consumer requires an ACTIVE stream.
for i in $(seq 1 30); do
  st=$(aws kinesis describe-stream-summary --stream-name "$STREAM" \
        --query 'StreamDescriptionSummary.StreamStatus' --output text 2>/dev/null || echo PENDING)
  [ "$st" = "ACTIVE" ] && break
  sleep 4
done
STREAM_ARN=$(aws kinesis describe-stream-summary --stream-name "$STREAM" \
  --query 'StreamDescriptionSummary.StreamARN' --output text)

# Enhanced-fan-out consumer registered outside Terraform.
aws kinesis register-stream-consumer \
  --stream-arn "$STREAM_ARN" \
  --consumer-name "$CONSUMER" \
  --query 'Consumer.ConsumerARN' --output text >/dev/null
echo "  Registered stream consumer '${CONSUMER}'"

echo "==> Setup complete"

# Private runtime metadata for the portal; do not copy into the agent workspace.
python3 - <<'PORTAL_STATE'
import json, os
json.dump({"region": os.environ["AWS_REGION"]}, open("seed_state.json", "w"), indent=2)
PORTAL_STATE
