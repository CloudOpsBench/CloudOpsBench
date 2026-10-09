#!/usr/bin/env bash
set -uo pipefail
python3 - <<'PY' 2>/dev/null || true
import boto3
s3=boto3.client("s3",region_name="us-east-1")
for b in s3.list_buckets().get("Buckets",[]):
    if b["Name"].startswith("vera2-"):
        try:
            import subprocess
            subprocess.run(["aws","s3","rb","s3://"+b["Name"],"--force"],capture_output=True)
        except Exception: pass
PY
# table buckets via CLI
for arn in $(aws s3tables list-table-buckets --region us-east-1 --query "tableBuckets[?starts_with(name,'vera2-')].arn" --output text 2>/dev/null); do
  aws s3tables delete-table-bucket --table-bucket-arn "$arn" --region us-east-1 2>/dev/null || true
done
exit 0
