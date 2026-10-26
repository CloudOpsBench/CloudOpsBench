#!/usr/bin/env bash
# Creates one general-purpose S3 bucket and one S3 table bucket with the vera2-
# prefix and records them in seed_state.json for the checker.
set -euo pipefail
REGION="us-east-1"
SUF="${RANDOM}${RANDOM}"
GP="vera2-data-${SUF}"
aws s3api create-bucket --bucket "$GP" --region "$REGION" >/dev/null
TB=$(aws s3tables create-table-bucket --name "vera2-warehouse-${SUF}" --region "$REGION" --query arn --output text)
python3 - "$REGION" "$GP" "$TB" <<'PY'
import json,sys
r,gp,tb=sys.argv[1:4]
json.dump({"region":r,"gp_bucket":gp,"table_bucket_arn":tb},open("seed_state.json","w"),indent=2)
PY
echo "seeded GP bucket $GP + S3 table bucket $TB"
