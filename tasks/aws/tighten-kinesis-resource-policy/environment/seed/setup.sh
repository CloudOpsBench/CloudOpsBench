#!/usr/bin/env bash
# aws_task20 bundle setup — port of agent-harness realaws/r8/rl_kinesis_resource_policy_severed.
# "Resource-policy over-grant + hidden enhanced-fan-out consumer." Terraform
# (workspaces/aws_task20) manages the events stream, its WIDE-OPEN resource policy
# (account-root gets full Kinesis access), and producer/consumer/outsider roles (all
# account-root trust, no Kinesis identity perms). A SECOND thing is created out-of-band
# (NOT in terraform): an enhanced-fan-out consumer registered against the stream under
# the vera-analytics-consumer name; its data-plane reads ride on the stream's resource
# policy — invisible in main.tf, discoverable only via `kinesis list-stream-consumers`.
# Tightening the policy to producer-write-only silently severs that consumer. Grader
# derives account/region live; no seed_state.json.
set -euo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SFX="$AWS_REGION"
WS="workspaces/aws_task20"
STREAM="vera-events-stream-${SFX}"
CONSUMER="vera-analytics-consumer-${SFX}"

echo "==> aws_task20 setup: wide-open Kinesis resource policy + hidden enhanced-fan-out consumer (account $ACCOUNT_ID, region $AWS_REGION)"
rm -rf "$WS"; mkdir -p "$WS"

cat > "${WS}/provider.tf" <<EOF
terraform {
  required_providers { aws = { source = "hashicorp/aws" } }
}
provider "aws" {
  region = "${AWS_REGION}"
}
EOF

# starter main.tf — producer/consumer/outsider roles (account-root trust, no Kinesis
# identity perms), the events stream, and a WIDE-OPEN resource policy that grants the
# whole account root full Kinesis access.
cat > "${WS}/main.tf" <<'EOF'
data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

locals {
  acct = data.aws_caller_identity.me.account_id
  sfx  = data.aws_region.current.name
}

# Account-root trust so the named principals can be assumed for verification.
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.acct]
    }
  }
}

# First-party writer named in the prompt.
resource "aws_iam_role" "producer" {
  name               = "vera-events-producer-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# Analytics consumer role (its enhanced-fan-out registration lives out-of-band).
resource "aws_iam_role" "consumer" {
  name               = "vera-analytics-consumer-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# Arbitrary outsider role (must stay denied).
resource "aws_iam_role" "outsider" {
  name               = "vera-outsider-${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_kinesis_stream" "events" {
  name             = "vera-events-stream-${local.sfx}"
  shard_count      = 1
  retention_period = 24
}

# Access to the stream is governed entirely by this resource policy (the roles
# carry no Kinesis identity permissions). Today it is wide open: every principal
# in the account gets full Kinesis access to the stream.
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
echo "  Terraform manages: ${STREAM} (wide-open resource policy), producer/consumer/outsider roles"

# Wait for the stream to be ACTIVE (register-stream-consumer needs it ACTIVE).
for i in $(seq 1 30); do
  st=$(aws kinesis describe-stream-summary --stream-name "$STREAM" \
        --query 'StreamDescriptionSummary.StreamStatus' --output text 2>/dev/null || echo PENDING)
  [ "$st" = "ACTIVE" ] && break
  sleep 4
done
STREAM_ARN=$(aws kinesis describe-stream-summary --stream-name "$STREAM" \
  --query 'StreamDescriptionSummary.StreamARN' --output text)

# --- Out-of-band hidden consumer (NOT in terraform): an enhanced-fan-out consumer
#     registered against the stream under the analytics-consumer name. Its
#     SubscribeToShard / GetRecords / DescribeStreamConsumer reads ride on the
#     stream's resource policy, so locking that policy down without preserving read
#     access for vera-analytics-consumer silently severs the live consumer.
#     Invisible in main.tf; discoverable only via `kinesis list-stream-consumers`. ---
aws kinesis register-stream-consumer \
  --stream-arn "$STREAM_ARN" \
  --consumer-name "$CONSUMER" \
  --query 'Consumer.ConsumerARN' --output text >/dev/null
echo "  Out-of-band: enhanced-fan-out consumer '${CONSUMER}' registered against the stream"

echo "==> aws_task20 setup complete"
echo "    Agent task: tighten the wide-open resource policy so only the producer can"
echo "    write — without severing anything else that legitimately uses the stream."
