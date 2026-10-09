#!/usr/bin/env bash
# Removes the pricing experiment: every object version, delete marker and
# unfinished upload under its prefix, plus its access point, Athena workgroup,
# secret (force-deleted) and IAM role. Finance's resources are left in place.
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

RESULTS_BUCKET="vera-analytics-results-${ACCOUNT}"
TARGET_PREFIX="price-test/"
TARGET_AP="price-test-results"
TARGET_WG="price-test"
TARGET_SECRET="vera/price-test/pricing-api-key"
TARGET_ROLE="vera-price-test-query-role"

echo "==> removing the Q1 price elasticity test"

# Read the workgroup's result location before the workgroup is deleted.
echo "--> reading the workgroup's result location first"
aws athena get-work-group --work-group "${TARGET_WG}" \
  --query 'WorkGroup.Configuration.ResultConfiguration.OutputLocation' \
  --output text 2>/dev/null || true

# Delete every version and delete marker; on a versioned bucket `s3 rm` only
# adds a delete marker.
echo "--> purging every version and delete marker under ${TARGET_PREFIX}"
for _pass in 1 2 3 4 5; do
  more=""
  for q in 'Versions[].[Key,VersionId]' 'DeleteMarkers[].[Key,VersionId]'; do
    while read -r k v; do
      [ -z "${k}" ] && continue
      [ "${k}" = "None" ] && continue
      aws s3api delete-object --bucket "${RESULTS_BUCKET}" --key "${k}" --version-id "${v}" \
        >/dev/null 2>&1 || true
      more="yes"
    done < <(aws s3api list-object-versions --bucket "${RESULTS_BUCKET}" \
               --prefix "${TARGET_PREFIX}" --max-keys 500 --query "${q}" --output text 2>/dev/null || true)
  done
  [ -n "${more}" ] || break
done

# Abort unfinished multipart uploads, which object listings do not show.
echo "--> aborting any unfinished upload under ${TARGET_PREFIX}"
while read -r k u; do
  [ -z "${k}" ] && continue
  [ "${k}" = "None" ] && continue
  aws s3api abort-multipart-upload --bucket "${RESULTS_BUCKET}" --key "${k}" --upload-id "${u}" \
    >/dev/null 2>&1 || true
done < <(aws s3api list-multipart-uploads --bucket "${RESULTS_BUCKET}" --prefix "${TARGET_PREFIX}" \
           --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null || true)

echo "--> deleting access point ${TARGET_AP}"
aws s3control delete-access-point --account-id "${ACCOUNT}" --name "${TARGET_AP}" \
  >/dev/null 2>&1 || true

echo "--> deleting athena workgroup ${TARGET_WG}"
aws athena delete-work-group --work-group "${TARGET_WG}" --recursive-delete-option \
  >/dev/null 2>&1 || true

# Force-delete the secret; a plain delete-secret leaves it restorable for the
# recovery window.
echo "--> destroying secret ${TARGET_SECRET} (force, not scheduled)"
aws secretsmanager delete-secret --secret-id "${TARGET_SECRET}" \
  --force-delete-without-recovery >/dev/null 2>&1 || true

echo "--> deleting IAM role ${TARGET_ROLE}"
for arn in $(aws iam list-attached-role-policies --role-name "${TARGET_ROLE}" \
              --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name "${TARGET_ROLE}" --policy-arn "${arn}" >/dev/null 2>&1 || true
done
for p in $(aws iam list-role-policies --role-name "${TARGET_ROLE}" \
            --query 'PolicyNames[]' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "${TARGET_ROLE}" --policy-name "${p}" >/dev/null 2>&1 || true
done
aws iam delete-role --role-name "${TARGET_ROLE}" >/dev/null 2>&1 || true

# The bucket and Finance's results, access point, workgroup, secret and role
# are left untouched.
echo "--> leaving Finance's weekly revenue reporting alone"

echo "==> pricing experiment removed"
