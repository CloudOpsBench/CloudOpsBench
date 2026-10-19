#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SUF="$(date +%s | tail -c 5)${RANDOM}"
BUCKET="vera2-${SUF}-lake"

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
fi
aws s3api wait bucket-exists --bucket "$BUCKET"

python3 - <<'PY'
import os
os.makedirs("/tmp/vera2-seed", exist_ok=True)
for n in ("ledger.csv", "notes.txt"):
    open("/tmp/vera2-seed/" + n, "w").write("pilot record\n")
PY
aws s3api put-object --bucket "$BUCKET" --key records/ledger.csv --body /tmp/vera2-seed/ledger.csv >/dev/null
aws s3api put-object --bucket "$BUCKET" --key records/notes.txt  --body /tmp/vera2-seed/notes.txt  >/dev/null

head -c 5242880 /dev/urandom > /tmp/vera2-seed/part1.bin
UP=$(aws s3api create-multipart-upload --bucket "$BUCKET" --key records/export.bin \
      --query UploadId --output text)
aws s3api upload-part --bucket "$BUCKET" --key records/export.bin --part-number 1 \
  --upload-id "$UP" --body /tmp/vera2-seed/part1.bin >/dev/null
rm -rf /tmp/vera2-seed

SEEN=$(aws s3api list-multipart-uploads --bucket "$BUCKET" \
        --query "Uploads[?UploadId=='${UP}'] | length(@)" --output text)
[ "$SEEN" = "1" ] || { echo "FATAL: multipart upload not in progress (seen=$SEEN)"; exit 1; }
HIDDEN=$(aws s3api list-objects-v2 --bucket "$BUCKET" \
          --query "Contents[?Key=='records/export.bin'] | length(@)" --output text 2>/dev/null || echo 0)
[ "$HIDDEN" = "0" ] || { echo "FATAL: the upload is visible to list-objects-v2 — no fence"; exit 1; }

python3 - "$REGION" "$BUCKET" "$UP" <<'PY'
import json, sys
json.dump({"region": sys.argv[1], "bucket": sys.argv[2], "upload_id": sys.argv[3],
           "upload_key": "records/export.bin"}, open("seed_state.json", "w"), indent=2)
PY
echo "seeded bucket $BUCKET with 2 objects + an in-progress multipart upload $UP (5MB of parts, invisible to list-objects-v2)"
