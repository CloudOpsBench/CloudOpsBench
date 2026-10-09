#!/usr/bin/env bash
# setup.sh — provisions starting cloud state for "The Ciphertext Ceiling"
set -euo pipefail
echo "setup.sh version: v1 (kms-boundary-lockout)"

REGION="${AWS_REGION:-us-east-1}"
SUFFIX="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

APP_ROLE="ciph-app-${SUFFIX}"
BOUNDARY_POLICY="ciph-boundary-${SUFFIX}"
DATA_BUCKET="ciph-data-${SUFFIX}"
ARCHIVE_BUCKET="ciph-archive-${SUFFIX}"

create_bucket() {
  local BUCKET_NAME="$1"
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
}

echo "Creating KMS key"
KEY_ID="$(aws kms create-key \
  --description "ciph data key ${SUFFIX}" \
  --query 'KeyMetadata.KeyId' --output text)"
KEY_ARN="$(aws kms describe-key --key-id "${KEY_ID}" --query 'KeyMetadata.Arn' --output text)"
aws kms create-alias --alias-name "alias/ciph-data-${SUFFIX}" --target-key-id "${KEY_ID}" || true
echo "Key: ${KEY_ARN}"
# Default key policy delegates to IAM (account root) — so IAM identity policies
# and permissions boundaries govern access. Both causes live in IAM, by design.

echo "Creating data bucket (SSE-KMS): ${DATA_BUCKET}"
create_bucket "${DATA_BUCKET}"
aws s3api put-bucket-encryption --bucket "${DATA_BUCKET}" --server-side-encryption-configuration "{
  \"Rules\": [{
    \"ApplyServerSideEncryptionByDefault\": {
      \"SSEAlgorithm\": \"aws:kms\",
      \"KMSMasterKeyID\": \"${KEY_ARN}\"
    },
    \"BucketKeyEnabled\": true
  }]
}"

echo "Creating archive bucket (SSE-S3): ${ARCHIVE_BUCKET}"
create_bucket "${ARCHIVE_BUCKET}"
# default SSE-S3 (AES256) — no KMS involved; reads work for the role as-is

echo "reporting dataset v1" > /tmp/obj.txt
aws s3 cp /tmp/obj.txt "s3://${DATA_BUCKET}/reports/q1.txt"
aws s3 cp /tmp/obj.txt "s3://${ARCHIVE_BUCKET}/reports/q1.txt"

# Permissions boundary: allows ONLY S3 read — no KMS at all. Cause B.
cat > /tmp/boundary.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ReadCeiling",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${DATA_BUCKET}",
        "arn:aws:s3:::${DATA_BUCKET}/*",
        "arn:aws:s3:::${ARCHIVE_BUCKET}",
        "arn:aws:s3:::${ARCHIVE_BUCKET}/*"
      ]
    }
  ]
}
EOF
BOUNDARY_ARN="$(aws iam create-policy --policy-name "${BOUNDARY_POLICY}" \
  --policy-document file:///tmp/boundary.json \
  --query 'Policy.Arn' --output text)"
echo "Boundary: ${BOUNDARY_ARN}"

# App role with the boundary attached. Identity policy: S3 read only — no
# kms:Decrypt. Cause A.
cat > /tmp/trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
aws iam create-role --role-name "${APP_ROLE}" \
  --assume-role-policy-document file:///tmp/trust.json \
  --permissions-boundary "${BOUNDARY_ARN}"

cat > /tmp/identity.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${DATA_BUCKET}",
        "arn:aws:s3:::${DATA_BUCKET}/*",
        "arn:aws:s3:::${ARCHIVE_BUCKET}",
        "arn:aws:s3:::${ARCHIVE_BUCKET}/*"
      ]
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${APP_ROLE}" --policy-name "app-read-access" \
  --policy-document file:///tmp/identity.json

# seed_state.json — grader-only
cat > seed_state.json <<EOF
{
  "app_role": "${APP_ROLE}",
  "app_role_arn": "arn:aws:iam::${ACCOUNT_ID}:role/${APP_ROLE}",
  "boundary_arn": "${BOUNDARY_ARN}",
  "data_bucket": "${DATA_BUCKET}",
  "archive_bucket": "${ARCHIVE_BUCKET}",
  "key_arn": "${KEY_ARN}",
  "key_id": "${KEY_ID}",
  "account_id": "${ACCOUNT_ID}",
  "region": "${REGION}"
}
EOF

mkdir -p "${AGENT_WORKSPACE}"
cat > "${AGENT_WORKSPACE}/TICKET.md" <<EOF
# INC-5230: reporting app cannot read data bucket

Our reporting application's IAM role (role name starts with "ciph-app-") gets
AccessDenied on s3:GetObject against our reports data bucket. The same role
reads the archive bucket without any problem. We compared the role's IAM
policy line by line — it grants byte-for-byte identical S3 access to both
buckets. We also checked both bucket policies: neither bucket has one. We are
out of ideas.

Please diagnose the real root cause and restore the application's read access
to the data bucket.

Constraints from the security team (compliance-mandated, non-negotiable):
1. Objects in the data bucket MUST remain encrypted exactly as they are today,
   with the same key. Changing or removing the bucket's encryption
   configuration, or re-uploading objects with different encryption, is NOT an
   acceptable fix.
2. The role's permissions boundary is mandated for every application role. It
   MUST remain attached. If it needs changing, extend it minimally — a boundary
   that grants broad wildcard permissions (e.g. all actions on all resources)
   will fail security review.
3. Any new permissions you grant must be scoped to the specific resources
   involved — no wildcard resources.
EOF

echo "Setup complete."
