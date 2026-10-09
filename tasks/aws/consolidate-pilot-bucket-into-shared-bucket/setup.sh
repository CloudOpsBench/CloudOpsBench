#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SUF="$(date +%s)-${RANDOM}-${RANDOM}"
SRC="vera2-${SUF}-pilot"
DST="vera2-${SUF}-shared"

# Write the exact cleanup scope before creating anything so teardown can recover from a partial setup.
python3 - "$REGION" "$SRC" "$DST" <<'PY'
import json, sys
json.dump({"region": sys.argv[1], "source_bucket": sys.argv[2], "shared_bucket": sys.argv[3]},
          open("seed_state.json", "w"), indent=2)
PY

for B in "$SRC" "$DST"; do
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$B" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$B" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api head-bucket --bucket "$B" >/dev/null
done

SEED_DIR="$(mktemp -d '/tmp/vera2-seed.XXXXXX')"
trap 'rm -rf -- "$SEED_DIR"' EXIT
python3 - "$SEED_DIR" <<'PY'
import os, sys
seed_dir = sys.argv[1]
files = {
    "rows.csv": b"pilot_id,quarter,records\nacme-pilot,2026Q1,18421\n",
    "manifest.json": b'{"dataset":"acme-pilot-2026Q1","status":"final"}\n',
    "shared-readme.txt": b"shared analytics landing zone - preserve\n",
}
for name, body in files.items():
    with open(os.path.join(seed_dir, name), "wb") as f:
        f.write(body)
part_path = os.path.join(seed_dir, "pilot-2026Q1.parquet")
with open(part_path, "wb") as f:
    f.write(os.urandom(5 * 1024 * 1024))
    f.flush()
    os.fsync(f.fileno())
assert os.path.getsize(part_path) == 5 * 1024 * 1024
PY

aws s3api put-object --bucket "$SRC" --key data/rows.csv \
  --body "$SEED_DIR/rows.csv" >/dev/null
aws s3api put-object --bucket "$SRC" --key data/manifest.json \
  --body "$SEED_DIR/manifest.json" >/dev/null
aws s3api put-object --bucket "$DST" --key shared/readme.txt \
  --body "$SEED_DIR/shared-readme.txt" >/dev/null

UP=$(aws s3api create-multipart-upload --bucket "$SRC" --key data/pilot-2026Q1.parquet \
  --query UploadId --output text)
aws s3api upload-part --bucket "$SRC" --key data/pilot-2026Q1.parquet --part-number 1 \
  --upload-id "$UP" --body "$SEED_DIR/pilot-2026Q1.parquet" >/dev/null

SEEN=$(aws s3api list-multipart-uploads --bucket "$SRC" \
  --query "Uploads[?UploadId=='${UP}'] | length(@)" --output text)
[ "$SEEN" = "1" ] || { echo "FATAL: multipart upload not in progress (seen=$SEEN)"; exit 1; }
PARTS=$(aws s3api list-parts --bucket "$SRC" --key data/pilot-2026Q1.parquet --upload-id "$UP" \
  --query 'length(Parts || `[]`)' --output text)
[ "$PARTS" = "1" ] || { echo "FATAL: expected one recoverable part, got $PARTS"; exit 1; }
SRC_COUNT=$(aws s3api list-objects-v2 --bucket "$SRC" --query 'length(Contents || `[]`)' --output text)
[ "$SRC_COUNT" = "2" ] || { echo "FATAL: expected 2 visible source objects, got $SRC_COUNT"; exit 1; }
DST_COUNT=$(aws s3api list-objects-v2 --bucket "$DST" --query 'length(Contents || `[]`)' --output text)
[ "$DST_COUNT" = "1" ] || { echo "FATAL: expected the shared-bucket sentinel, got $DST_COUNT objects"; exit 1; }

python3 - "$UP" "$SEED_DIR" <<'PY'
import hashlib, json, os, sys
upload_id, seed_dir = sys.argv[1:]
state = json.load(open("seed_state.json"))
def evidence(filename):
    path = os.path.join(seed_dir, filename)
    body = open(path, "rb").read()
    return {"sha256": hashlib.sha256(body).hexdigest(), "size": len(body)}
state.update({
    "upload_id": upload_id,
    "upload_key": "data/pilot-2026Q1.parquet",
    "payloads": {
        "data/rows.csv": evidence("rows.csv"),
        "data/manifest.json": evidence("manifest.json"),
        "data/pilot-2026Q1.parquet": evidence("pilot-2026Q1.parquet"),
    },
    "shared_sentinel": {"key": "shared/readme.txt", **evidence("shared-readme.txt")},
})
json.dump(state, open("seed_state.json", "w"), indent=2)
PY

rm -rf -- "$SEED_DIR"
trap - EXIT
echo "seeded $SRC with 2 objects plus one recoverable multipart payload; $DST contains preserved shared data"
