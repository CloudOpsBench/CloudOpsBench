#!/usr/bin/env bash
# Tears down the pricing experiment fixture. Access points are removed before
# the bucket, multipart uploads are aborted so the bucket can be deleted, and
# secrets are force-deleted so the next setup can recreate them. Tolerates
# resources that are already gone.
set -euo pipefail

_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s [teardown] %s\n' "$(_ts)" "$*" >&2; }

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

RESULTS_BUCKET="vera-analytics-results-${ACCOUNT}"
ACCESS_POINTS="price-test-results finance-reporting"
WORKGROUPS="price-test finance-reporting"
SECRETS="vera/price-test/pricing-api-key vera/finance/warehouse-dsn"
ROLES="vera-price-test-query-role vera-finance-reporting-role"

log "==== tearing down pricing experiment fixture in ${REGION} ===="

for ap in ${ACCESS_POINTS}; do
  log "access point ${ap}"
  aws s3control delete-access-point --account-id "${ACCOUNT}" --name "${ap}" \
    >/dev/null 2>&1 || true
done

for wg in ${WORKGROUPS}; do
  log "workgroup ${wg}"
  aws athena delete-work-group --work-group "${wg}" --recursive-delete-option \
    >/dev/null 2>&1 || true
done

log "bucket ${RESULTS_BUCKET}"
if aws s3api head-bucket --bucket "${RESULTS_BUCKET}" >/dev/null 2>&1; then
  while read -r k u; do
    [ -z "${k}" ] && continue
    [ "${k}" = "None" ] && continue
    aws s3api abort-multipart-upload --bucket "${RESULTS_BUCKET}" --key "${k}" --upload-id "${u}" \
      >/dev/null 2>&1 || true
  done < <(aws s3api list-multipart-uploads --bucket "${RESULTS_BUCKET}" \
             --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null || true)
  for _pass in 1 2 3 4 5; do
    more=""
    for q in 'Versions[].[Key,VersionId]' 'DeleteMarkers[].[Key,VersionId]'; do
      while read -r k v; do
        [ -z "${k}" ] && continue
        [ "${k}" = "None" ] && continue
        aws s3api delete-object --bucket "${RESULTS_BUCKET}" --key "${k}" --version-id "${v}" \
          >/dev/null 2>&1 || true
        more="yes"
      done < <(aws s3api list-object-versions --bucket "${RESULTS_BUCKET}" --max-keys 500 \
                 --query "${q}" --output text 2>/dev/null || true)
    done
    [ -n "${more}" ] || break
  done
  aws s3api delete-bucket --bucket "${RESULTS_BUCKET}" >/dev/null 2>&1 || true
fi

for s in ${SECRETS}; do
  log "secret ${s}"
  aws secretsmanager delete-secret --secret-id "${s}" --force-delete-without-recovery \
    >/dev/null 2>&1 || true
done

for r in ${ROLES}; do
  log "role ${r}"
  for arn in $(aws iam list-attached-role-policies --role-name "${r}" \
                --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${r}" --policy-arn "${arn}" >/dev/null 2>&1 || true
  done
  for p in $(aws iam list-role-policies --role-name "${r}" \
              --query 'PolicyNames[]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "${r}" --policy-name "${p}" >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "${r}" >/dev/null 2>&1 || true
done

log "==== teardown complete ===="
echo "teardown complete"
