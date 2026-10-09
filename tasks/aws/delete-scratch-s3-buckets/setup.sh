#!/usr/bin/env bash
set -euo pipefail
REGION="us-east-1"
AZID="use1-az4"
SUF="${RANDOM}${RANDOM}"
G1="vera2-logs-${SUF}"
G2="vera2-assets-${SUF}"
DB="vera2-cache-${SUF}--${AZID}--x-s3"

aws s3api create-bucket --bucket "$G1" --region "$REGION" >/dev/null
aws s3api create-bucket --bucket "$G2" --region "$REGION" >/dev/null

aws s3api create-bucket --bucket "$DB" --region "$REGION" \
  --create-bucket-configuration "{\"Location\":{\"Type\":\"AvailabilityZone\",\"Name\":\"${AZID}\"},\"Bucket\":{\"Type\":\"Directory\",\"DataRedundancy\":\"SingleAvailabilityZone\"}}" >/dev/null

python3 - "$REGION" "$G1" "$G2" "$DB" <<'PY'
import json,sys
r,g1,g2,db=sys.argv[1:5]
json.dump({"region":r,"general_buckets":[g1,g2],"dir_buckets":[db],"all":[g1,g2,db]},
          open("seed_state.json","w"),indent=2)
PY
echo "seeded 2 general-purpose buckets and 1 directory bucket: $G1 $G2 $DB"
