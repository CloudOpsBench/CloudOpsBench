#!/usr/bin/env bash
# solution.sh — reference solution. Discovers everything at runtime;
# never reads seed_state.json.
set -euo pipefail

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# 1. Discover the app role
APP_ROLE="$(aws iam list-roles --query 'Roles[?starts_with(RoleName, `ciph-app-`)].RoleName' --output text | head -n1)"
echo "App role: ${APP_ROLE}"

# 2. Discover the data bucket and its KMS key from the bucket encryption config.
#    The data bucket is the ciph-* bucket whose default encryption is aws:kms.
DATA_BUCKET=""
KEY_ARN=""
for BUCKET in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  case "${BUCKET}" in
    ciph-*) ;;
    *) continue ;;
  esac
  ALGO="$(aws s3api get-bucket-encryption --bucket "${BUCKET}" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text 2>/dev/null || echo "none")"
  if [ "${ALGO}" = "aws:kms" ]; then
    DATA_BUCKET="${BUCKET}"
    KEY_ARN="$(aws s3api get-bucket-encryption --bucket "${BUCKET}" \
      --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
      --output text)"
  fi
done
echo "Data bucket: ${DATA_BUCKET} — KMS key: ${KEY_ARN}"

# Normalize to full key ARN if the config stored a bare key id
case "${KEY_ARN}" in
  arn:aws:kms:*) ;;
  *) KEY_ARN="$(aws kms describe-key --key-id "${KEY_ARN}" --query 'KeyMetadata.Arn' --output text)" ;;
esac

# 3. Cause A — identity policy: add kms:Decrypt scoped to the specific key.
cat > /tmp/kms-identity.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DecryptDataKey",
      "Effect": "Allow",
      "Action": ["kms:Decrypt"],
      "Resource": ["${KEY_ARN}"]
    }
  ]
}
EOF
aws iam put-role-policy --role-name "${APP_ROLE}" --policy-name "kms-decrypt-data" \
  --policy-document file:///tmp/kms-identity.json
echo "Identity policy: added kms:Decrypt scoped to the data key."

# 4. Cause B — permissions boundary: effective permissions are the INTERSECTION
#    of identity policy and boundary. The boundary allows only S3, so extend it
#    minimally with the same scoped kms:Decrypt, keeping everything else as-is.
BOUNDARY_ARN="$(aws iam get-role --role-name "${APP_ROLE}" \
  --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text)"
echo "Boundary: ${BOUNDARY_ARN}"

CURRENT_VERSION="$(aws iam get-policy --policy-arn "${BOUNDARY_ARN}" \
  --query 'Policy.DefaultVersionId' --output text)"
aws iam get-policy-version --policy-arn "${BOUNDARY_ARN}" --version-id "${CURRENT_VERSION}" \
  --query 'PolicyVersion.Document' --output json > /tmp/boundary-current.json

python3 - "${KEY_ARN}" /tmp/boundary-current.json /tmp/boundary-new.json <<'PYEOF'
import json, sys
key_arn, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(src))
doc.setdefault("Statement", []).append({
    "Sid": "DecryptDataKeyCeiling",
    "Effect": "Allow",
    "Action": ["kms:Decrypt"],
    "Resource": [key_arn],
})
json.dump(doc, open(dst, "w"))
PYEOF

aws iam create-policy-version --policy-arn "${BOUNDARY_ARN}" \
  --policy-document file:///tmp/boundary-new.json --set-as-default
echo "Boundary: minimally extended with scoped kms:Decrypt (still attached, S3 ceiling preserved)."

echo "Remediation complete — both layers fixed."
