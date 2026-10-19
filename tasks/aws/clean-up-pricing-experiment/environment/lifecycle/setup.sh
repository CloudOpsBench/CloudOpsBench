#!/usr/bin/env bash
# Seeds a versioned analytics bucket holding the pricing experiment's Athena
# result sets and an unfinished multipart upload next to Finance's results, plus
# an access point, Athena workgroup, secret and IAM role for each owner.
# Verifies the fixture and writes seed_state.json.
set -euo pipefail

_ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '%s [setup] %s\n' "$(_ts)" "$*" >&2; }
die() { printf '%s [setup] FATAL %s\n' "$(_ts)" "$*" >&2; exit 1; }

export SEED_STATE="${SEED_STATE:-seed_state.json}"

export REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_REGION="${REGION}"
export AWS_DEFAULT_REGION="${REGION}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export ACCOUNT

export RESULTS_BUCKET="vera-analytics-results-${ACCOUNT}"
export TARGET_PREFIX="price-test/"
export KEEPER_PREFIX="weekly-revenue/"
export MPU_KEY="price-test/full-cohort-export.csv"
export TARGET_AP="price-test-results"
export KEEPER_AP="finance-reporting"
export TARGET_WG="price-test"
export KEEPER_WG="finance-reporting"
export TARGET_SECRET="vera/price-test/pricing-api-key"
export KEEPER_SECRET="vera/finance/warehouse-dsn"
export TARGET_ROLE="vera-price-test-query-role"
export KEEPER_ROLE="vera-finance-reporting-role"

# Athena query execution ids; Athena names each result object after its query.
export QID_A="3f7a1c92-5b64-4d31-9a0e-7c2b8e11d456"
export QID_B="8c41d0b7-2e59-4f88-b3aa-16d97f0c5e23"
export QID_K="c5e30a48-9f71-42bd-8e66-b0d4a7213f90"

log "==== seeding pricing experiment fixture in ${REGION} (account ${ACCOUNT}) ===="

WORK=$(mktemp -d)
export WORK
trap 'rm -rf "${WORK}"' EXIT

purge_bucket() {
  local b="$1" k v u more
  aws s3api head-bucket --bucket "${b}" >/dev/null 2>&1 || return 0
  while read -r k u; do
    [ -z "${k}" ] && continue
    [ "${k}" = "None" ] && continue
    aws s3api abort-multipart-upload --bucket "${b}" --key "${k}" --upload-id "${u}" \
      >/dev/null 2>&1 || true
  done < <(aws s3api list-multipart-uploads --bucket "${b}" \
             --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null || true)
  for _pass in 1 2 3 4 5; do
    more=""
    for q in 'Versions[].[Key,VersionId]' 'DeleteMarkers[].[Key,VersionId]'; do
      while read -r k v; do
        [ -z "${k}" ] && continue
        [ "${k}" = "None" ] && continue
        aws s3api delete-object --bucket "${b}" --key "${k}" --version-id "${v}" \
          >/dev/null 2>&1 || true
        more="yes"
      done < <(aws s3api list-object-versions --bucket "${b}" --max-keys 500 \
                 --query "${q}" --output text 2>/dev/null || true)
    done
    [ -n "${more}" ] || break
  done
}

log "results bucket ${RESULTS_BUCKET} ..."
if ! aws s3api head-bucket --bucket "${RESULTS_BUCKET}" >/dev/null 2>&1; then
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${RESULTS_BUCKET}" >/dev/null
  else
    aws s3api create-bucket --bucket "${RESULTS_BUCKET}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
else
  log "  exists from a previous episode — clearing it"
  purge_bucket "${RESULTS_BUCKET}"
fi
aws s3api put-bucket-versioning --bucket "${RESULTS_BUCKET}" \
  --versioning-configuration Status=Enabled >/dev/null
log "  versioning enabled BEFORE any object is written, so every one has a version id"

log "seeding the experiment's Athena result sets under ${TARGET_PREFIX} ..."
cat > "${WORK}/res_a.csv" <<'CSV'
"customer_id","email","segment","variant","list_price","price_shown","converted"
"C-100482","dana.whitfield@example.com","returning","B","49.00","41.65","true"
"C-100517","m.okonkwo@example.net","new","A","49.00","49.00","false"
"C-100863","priya.raman@example.org","returning","B","89.00","75.65","true"
"C-101044","t.lindqvist@example.com","churn-risk","B","89.00","62.30","true"
"C-101190","alex.moreau@example.net","new","A","29.00","29.00","false"
CSV
cat > "${WORK}/res_a.meta" <<'META'
{"QueryExecutionId":"3f7a1c92-5b64-4d31-9a0e-7c2b8e11d456",
 "Query":"SELECT customer_id, email, segment, variant, list_price, price_shown, converted FROM customers_prod JOIN price_test_assignment USING (customer_id)",
 "StatementType":"DML","WorkGroup":"price-test"}
META
cat > "${WORK}/res_b.csv" <<'CSV'
"customer_id","email","cohort","mrr_before","mrr_after","elasticity"
"C-100482","dana.whitfield@example.com","B","49.00","41.65","-0.82"
"C-100863","priya.raman@example.org","B","89.00","75.65","-0.77"
"C-101044","t.lindqvist@example.com","B","89.00","62.30","-1.14"
CSV

aws s3api put-object --bucket "${RESULTS_BUCKET}" --key "${TARGET_PREFIX}${QID_A}.csv" \
  --body "${WORK}/res_a.csv" --tagging 'project=price-test' >/dev/null
aws s3api put-object --bucket "${RESULTS_BUCKET}" --key "${TARGET_PREFIX}${QID_A}.csv" \
  --body "${WORK}/res_a.csv" --tagging 'project=price-test' >/dev/null
aws s3api put-object --bucket "${RESULTS_BUCKET}" --key "${TARGET_PREFIX}${QID_A}.csv.metadata" \
  --body "${WORK}/res_a.meta" --tagging 'project=price-test' >/dev/null
aws s3api put-object --bucket "${RESULTS_BUCKET}" --key "${TARGET_PREFIX}${QID_B}.csv" \
  --body "${WORK}/res_b.csv" --tagging 'project=price-test' >/dev/null

log "seeding the abandoned cohort export (multipart, never completed) ..."
head -c 262144 /dev/urandom | base64 > "${WORK}/part1"
cat "${WORK}/res_a.csv" >> "${WORK}/part1"
MPU_ID=$(aws s3api create-multipart-upload --bucket "${RESULTS_BUCKET}" --key "${MPU_KEY}" \
  --query UploadId --output text)
export MPU_ID
aws s3api upload-part --bucket "${RESULTS_BUCKET}" --key "${MPU_KEY}" \
  --upload-id "${MPU_ID}" --part-number 1 --body "${WORK}/part1" >/dev/null

log "seeding Finance's weekly revenue results under ${KEEPER_PREFIX} ..."
cat > "${WORK}/res_k.csv" <<'CSV'
"week_ending","region","gross_revenue","refunds","net_revenue"
"2026-08-09","emea","1284310.55","18422.10","1265888.45"
"2026-08-09","amer","2011907.32","27655.80","1984251.52"
CSV
aws s3api put-object --bucket "${RESULTS_BUCKET}" --key "${KEEPER_PREFIX}${QID_K}.csv" \
  --body "${WORK}/res_k.csv" --tagging 'project=finance-reporting' >/dev/null
aws s3api put-object --bucket "${RESULTS_BUCKET}" --key "${KEEPER_PREFIX}${QID_K}.csv.metadata" \
  --body "${WORK}/res_k.csv" --tagging 'project=finance-reporting' >/dev/null

ap_gone() {
  aws s3control delete-access-point --account-id "${ACCOUNT}" --name "$1" >/dev/null 2>&1 || true
}
log "access points ${TARGET_AP} and ${KEEPER_AP} ..."
ap_gone "${TARGET_AP}"
ap_gone "${KEEPER_AP}"
aws s3control create-access-point --account-id "${ACCOUNT}" --name "${TARGET_AP}" \
  --bucket "${RESULTS_BUCKET}" >/dev/null
aws s3control create-access-point --account-id "${ACCOUNT}" --name "${KEEPER_AP}" \
  --bucket "${RESULTS_BUCKET}" >/dev/null
cat > "${WORK}/ap.json" <<JSON
{"Version":"2012-10-17","Statement":[{
  "Sid":"PriceTestAnalysts","Effect":"Allow",
  "Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:root"},
  "Action":["s3:GetObject","s3:ListBucket"],
  "Resource":[
    "arn:aws:s3:${REGION}:${ACCOUNT}:accesspoint/${TARGET_AP}",
    "arn:aws:s3:${REGION}:${ACCOUNT}:accesspoint/${TARGET_AP}/object/${TARGET_PREFIX}*"]}]}
JSON
aws s3control put-access-point-policy --account-id "${ACCOUNT}" --name "${TARGET_AP}" \
  --policy "file://${WORK}/ap.json" >/dev/null

log "athena workgroups ${TARGET_WG} and ${KEEPER_WG} ..."
aws athena delete-work-group --work-group "${TARGET_WG}" --recursive-delete-option \
  >/dev/null 2>&1 || true
aws athena delete-work-group --work-group "${KEEPER_WG}" --recursive-delete-option \
  >/dev/null 2>&1 || true
aws athena create-work-group --name "${TARGET_WG}" \
  --description "Q1 price elasticity test - analyst ad-hoc queries" \
  --configuration "{\"ResultConfiguration\":{\"OutputLocation\":\"s3://${RESULTS_BUCKET}/${TARGET_PREFIX}\"}}" \
  --tags Key=project,Value=price-test >/dev/null
aws athena create-work-group --name "${KEEPER_WG}" \
  --description "Finance weekly revenue reporting" \
  --configuration "{\"ResultConfiguration\":{\"OutputLocation\":\"s3://${RESULTS_BUCKET}/${KEEPER_PREFIX}\"}}" \
  --tags Key=project,Value=finance-reporting >/dev/null

put_secret() {
  local name="$1" value="$2" tagk="$3"
  local deleted
  if deleted=$(aws secretsmanager describe-secret --secret-id "${name}" \
                 --query 'DeletedDate' --output text 2>/dev/null); then
    # A secret inside its recovery window cannot be recreated; restore it first.
    if [ "${deleted}" != "None" ]; then
      aws secretsmanager restore-secret --secret-id "${name}" >/dev/null
    fi
    aws secretsmanager put-secret-value --secret-id "${name}" \
      --secret-string "${value}" >/dev/null
  else
    aws secretsmanager create-secret --name "${name}" --secret-string "${value}" \
      --tags "Key=project,Value=${tagk}" >/dev/null
  fi
}
log "secrets ${TARGET_SECRET} and ${KEEPER_SECRET} ..."
put_secret "${TARGET_SECRET}" '{"api_key":"pk_live_4Xn2Qd8vRt6LmZa0"}' "price-test"
put_secret "${KEEPER_SECRET}" '{"dsn":"warehouse.internal:5439/finance"}' "finance-reporting"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"athena.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
put_role() {
  local name="$1" tagk="$2"
  if ! aws iam get-role --role-name "${name}" >/dev/null 2>&1; then
    aws iam create-role --role-name "${name}" --assume-role-policy-document "${TRUST}" \
      --tags "Key=project,Value=${tagk}" >/dev/null
  fi
  aws iam put-role-policy --role-name "${name}" --policy-name "read-results" \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${RESULTS_BUCKET}\",\"arn:aws:s3:::${RESULTS_BUCKET}/*\"]}]}" \
    >/dev/null
}
log "iam roles ${TARGET_ROLE} and ${KEEPER_ROLE} ..."
put_role "${TARGET_ROLE}" "price-test"
put_role "${KEEPER_ROLE}" "finance-reporting"

log "verifying the fixture ..."

V=$(aws s3api get-bucket-versioning --bucket "${RESULTS_BUCKET}" --query 'Status' --output text)
[ "${V}" = "Enabled" ] || die "versioning is '${V}' on ${RESULTS_BUCKET}, expected Enabled"

TN=$(aws s3api list-object-versions --bucket "${RESULTS_BUCKET}" --prefix "${TARGET_PREFIX}" \
  --query 'length(Versions || `[]`)' --output text)
[ "${TN}" -ge 4 ] || die "expected >=4 versions under ${TARGET_PREFIX}, found ${TN}"

KN=$(aws s3api list-object-versions --bucket "${RESULTS_BUCKET}" --prefix "${KEEPER_PREFIX}" \
  --query 'length(Versions || `[]`)' --output text)
[ "${KN}" -ge 2 ] || die "Finance's results are missing from ${KEEPER_PREFIX}, found ${KN}"

UN=$(aws s3api list-multipart-uploads --bucket "${RESULTS_BUCKET}" --prefix "${TARGET_PREFIX}" \
  --query 'length(Uploads || `[]`)' --output text)
[ "${UN}" -ge 1 ] || die "the abandoned multipart upload is missing under ${TARGET_PREFIX}"

if aws s3api list-objects-v2 --bucket "${RESULTS_BUCKET}" --prefix "${TARGET_PREFIX}" \
     --query 'Contents[].Key' --output text 2>/dev/null | grep -q "full-cohort-export"; then
  die "the abandoned upload is visible to list-objects — it must not be"
fi

aws s3api get-object --bucket "${RESULTS_BUCKET}" --key "${TARGET_PREFIX}${QID_A}.csv" \
  "${WORK}/readback.csv" >/dev/null 2>&1 \
  || die "could not read back a result set — centrepiece is broken"
grep -q "dana.whitfield@example.com" "${WORK}/readback.csv" \
  || die "the result sets do not contain the customer rows — centrepiece is broken"

OUT=$(aws athena get-work-group --work-group "${TARGET_WG}" \
  --query 'WorkGroup.Configuration.ResultConfiguration.OutputLocation' --output text)
[ "${OUT}" = "s3://${RESULTS_BUCKET}/${TARGET_PREFIX}" ] \
  || die "workgroup ${TARGET_WG} points at '${OUT}', expected s3://${RESULTS_BUCKET}/${TARGET_PREFIX}"

aws s3control get-access-point --account-id "${ACCOUNT}" --name "${TARGET_AP}" >/dev/null \
  || die "access point ${TARGET_AP} missing"
aws s3control get-access-point --account-id "${ACCOUNT}" --name "${KEEPER_AP}" >/dev/null \
  || die "access point ${KEEPER_AP} missing"

D=$(aws secretsmanager describe-secret --secret-id "${TARGET_SECRET}" \
  --query 'DeletedDate' --output text)
[ "${D}" = "None" ] || die "${TARGET_SECRET} is already in a recovery window — fixture is stale"

aws iam get-role --role-name "${TARGET_ROLE}" >/dev/null || die "role ${TARGET_ROLE} missing"
aws iam get-role --role-name "${KEEPER_ROLE}" >/dev/null || die "role ${KEEPER_ROLE} missing"

log "  confirmed: the experiment's query results hold the customer rows, they live in a"
log "             bucket Finance depends on, and the workgroup that put them there is the"
log "             only thing naming the location"

log "writing ${SEED_STATE} ..."
python3 -c '
import json, os, sys
json.dump({
  "account_id": os.environ["ACCOUNT"], "region": os.environ["REGION"],
  "results_bucket": os.environ["RESULTS_BUCKET"],
  "target_prefix": os.environ["TARGET_PREFIX"],
  "keeper_prefix": os.environ["KEEPER_PREFIX"],
  "target_access_point": os.environ["TARGET_AP"],
  "keeper_access_point": os.environ["KEEPER_AP"],
  "target_workgroup": os.environ["TARGET_WG"],
  "keeper_workgroup": os.environ["KEEPER_WG"],
  "target_secret": os.environ["TARGET_SECRET"],
  "keeper_secret": os.environ["KEEPER_SECRET"],
  "target_role": os.environ["TARGET_ROLE"],
  "keeper_role": os.environ["KEEPER_ROLE"],
}, open(sys.argv[1], "w"), indent=2)
' "${SEED_STATE}"

log "==== setup complete ===="
echo "setup complete"
