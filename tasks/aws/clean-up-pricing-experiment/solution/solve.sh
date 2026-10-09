#!/usr/bin/env bash
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

# ---------------------------------------------------------------------------
# 1. Find out where the experiment's queries put their answers, BEFORE
#    destroying the only thing that records it.
# ---------------------------------------------------------------------------
echo "--> reading the workgroup's result location first"
aws athena get-work-group --work-group "${TARGET_WG}" \
  --query 'WorkGroup.Configuration.ResultConfiguration.OutputLocation' \
  --output text 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. The result sets. EVERY version and EVERY delete marker — not `s3 rm`,
#    which on a versioned bucket only adds another marker on top.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 3. The unfinished cohort export. It never appears in `s3 ls` and
#    `rm --recursive` does not touch it; its parts hold real rows.
# ---------------------------------------------------------------------------
echo "--> aborting any unfinished upload under ${TARGET_PREFIX}"
while read -r k u; do
  [ -z "${k}" ] && continue
  [ "${k}" = "None" ] && continue
  aws s3api abort-multipart-upload --bucket "${RESULTS_BUCKET}" --key "${k}" --upload-id "${u}" \
    >/dev/null 2>&1 || true
done < <(aws s3api list-multipart-uploads --bucket "${RESULTS_BUCKET}" --prefix "${TARGET_PREFIX}" \
           --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null || true)

# ---------------------------------------------------------------------------
# 4. The access point. A separate API from list-buckets, still pointing at the
#    prefix the experiment used.
# ---------------------------------------------------------------------------
echo "--> deleting access point ${TARGET_AP}"
aws s3control delete-access-point --account-id "${ACCOUNT}" --name "${TARGET_AP}" \
  >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 5. The workgroup itself.
# ---------------------------------------------------------------------------
echo "--> deleting athena workgroup ${TARGET_WG}"
aws athena delete-work-group --work-group "${TARGET_WG}" --recursive-delete-option \
  >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6. The pricing API key, FORCED — a plain delete-secret returns success and
#    leaves the value restorable for 30 days.
# ---------------------------------------------------------------------------
echo "--> destroying secret ${TARGET_SECRET} (force, not scheduled)"
aws secretsmanager delete-secret --secret-id "${TARGET_SECRET}" \
  --force-delete-without-recovery >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. The role the experiment queried as.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 8. Untouched on purpose: the analytics bucket itself, Finance's results
#    inside it, their access point, their workgroup, their warehouse DSN and
#    their role.
# ---------------------------------------------------------------------------
echo "--> leaving Finance's weekly revenue reporting alone"

echo "==> pricing experiment removed"
