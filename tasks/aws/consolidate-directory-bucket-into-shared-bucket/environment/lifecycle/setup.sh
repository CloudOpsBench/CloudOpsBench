#!/usr/bin/env bash
# Creates an S3 Express directory bucket, a shared general-purpose bucket and a control
# bucket. The directory bucket gets two objects plus an in-progress multipart upload with
# one uploaded part. Object hashes are recorded in seed_state.json for the checker.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
AZID="use1-az4"
SUFFIX="$(python3 -c 'import secrets; print(secrets.token_hex(7))')"
SOURCE="vera2-${SUFFIX}-pilot--${AZID}--x-s3"
DESTINATION="vera2-${SUFFIX}-shared"
CONTROL="vera2-${SUFFIX}-control"

python3 - "$REGION" "$SOURCE" "$DESTINATION" "$CONTROL" <<'PY'
import json
import sys

json.dump(
    {
        "region": sys.argv[1],
        "source_bucket": sys.argv[2],
        "shared_bucket": sys.argv[3],
        "control_bucket": sys.argv[4],
    },
    open("seed_state.json", "w"),
    indent=2,
)
PY

aws s3api create-bucket --bucket "$SOURCE" --region "$REGION" \
  --create-bucket-configuration "{\"Location\":{\"Type\":\"AvailabilityZone\",\"Name\":\"${AZID}\"},\"Bucket\":{\"Type\":\"Directory\",\"DataRedundancy\":\"SingleAvailabilityZone\"}}" >/dev/null

for bucket in "$DESTINATION" "$CONTROL"; do
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$bucket" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
done

for bucket in "$SOURCE" "$DESTINATION" "$CONTROL"; do
  ready=0
  for _ in $(seq 1 20); do
    if aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  [ "$ready" = "1" ] || { echo "FATAL: bucket never became ready: $bucket"; exit 1; }
done

SEED_DIR="$(mktemp -d /tmp/vera2-s3express-seed.XXXXXX)"
trap 'rm -rf -- "$SEED_DIR"' EXIT
python3 - "$SEED_DIR" <<'PY'
import os
import sys

root = sys.argv[1]
payloads = {
    "rows.csv": b"pilot_id,quarter,records\\nacme-pilot,2026Q1,18421\\n",
    "manifest.json": b'{"dataset":"acme-pilot-2026Q1","status":"final"}\\n',
    "shared-readme.txt": b"shared analytics landing zone - preserve\\n",
    "control-note.txt": b"unrelated control data - preserve\\n",
}
for name, body in payloads.items():
    with open(os.path.join(root, name), "wb") as handle:
        handle.write(body)

with open(os.path.join(root, "pilot-2026Q1.parquet"), "wb") as handle:
    handle.write(os.urandom(5 * 1024 * 1024))
    handle.flush()
    os.fsync(handle.fileno())
PY

aws s3api put-object --bucket "$SOURCE" --key data/rows.csv \
  --body "$SEED_DIR/rows.csv" --content-type text/csv >/dev/null
aws s3api put-object --bucket "$SOURCE" --key data/manifest.json \
  --body "$SEED_DIR/manifest.json" --content-type application/json >/dev/null
aws s3api put-object --bucket "$DESTINATION" --key shared/readme.txt \
  --body "$SEED_DIR/shared-readme.txt" --content-type text/plain >/dev/null
aws s3api put-object --bucket "$CONTROL" --key controls/leave.txt \
  --body "$SEED_DIR/control-note.txt" --content-type text/plain >/dev/null

UPLOAD_ID="$(aws s3api create-multipart-upload --bucket "$SOURCE" --key data/pilot-2026Q1.parquet \
  --content-type application/octet-stream --query UploadId --output text)"
aws s3api upload-part --bucket "$SOURCE" --key data/pilot-2026Q1.parquet --part-number 1 \
  --upload-id "$UPLOAD_ID" --body "$SEED_DIR/pilot-2026Q1.parquet" >/dev/null

uploads="$(aws s3api list-multipart-uploads --bucket "$SOURCE" \
  --query "Uploads[?UploadId=='${UPLOAD_ID}'] | length(@)" --output text)"
[ "$uploads" = "1" ] || { echo "FATAL: expected one source multipart upload, got $uploads"; exit 1; }
parts="$(aws s3api list-parts --bucket "$SOURCE" --key data/pilot-2026Q1.parquet \
  --upload-id "$UPLOAD_ID" --query 'length(Parts || `[]`)' --output text)"
[ "$parts" = "1" ] || { echo "FATAL: expected one uploaded part, got $parts"; exit 1; }
visible="$(aws s3api list-objects-v2 --bucket "$SOURCE" --query 'length(Contents || `[]`)' --output text)"
[ "$visible" = "2" ] || { echo "FATAL: expected two visible pilot objects, got $visible"; exit 1; }
shared_visible="$(aws s3api list-objects-v2 --bucket "$DESTINATION" --query 'length(Contents || `[]`)' --output text)"
[ "$shared_visible" = "1" ] || { echo "FATAL: expected one shared sentinel, got $shared_visible"; exit 1; }

python3 - "$UPLOAD_ID" "$SEED_DIR" <<'PY'
import hashlib
import json
import os
import sys

upload_id, seed_dir = sys.argv[1:]
state = json.load(open("seed_state.json"))

def evidence(filename):
    body = open(os.path.join(seed_dir, filename), "rb").read()
    return {"sha256": hashlib.sha256(body).hexdigest(), "size": len(body)}

state.update(
    {
        "upload_id": upload_id,
        "upload_key": "data/pilot-2026Q1.parquet",
        "pilot_payloads": {
            "data/rows.csv": evidence("rows.csv"),
            "data/manifest.json": evidence("manifest.json"),
            "data/pilot-2026Q1.parquet": evidence("pilot-2026Q1.parquet"),
        },
        "shared_sentinel": {"key": "shared/readme.txt", **evidence("shared-readme.txt")},
        "control_sentinel": {"key": "controls/leave.txt", **evidence("control-note.txt")},
    }
)
json.dump(state, open("seed_state.json", "w"), indent=2)
PY

echo "seeded directory source $SOURCE with two objects plus a recoverable multipart payload; shared destination and control bucket are preserved"
