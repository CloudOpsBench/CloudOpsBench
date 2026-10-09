#!/usr/bin/env bash
set -uo pipefail
python3 - <<'PYEOF' 2>/dev/null || true
import json, boto3
try:
    s = json.load(open("seed_state.json"))
except Exception:
    raise SystemExit
r = s.get("region", "us-east-1")
s3 = boto3.client("s3", region_name=r)
for b in s.get("general_buckets", []):
    try:
        for o in s3.list_objects_v2(Bucket=b).get("Contents", []):
            s3.delete_object(Bucket=b, Key=o["Key"])
        s3.delete_bucket(Bucket=b)
    except Exception:
        pass
for b in s.get("dir_buckets", []):
    try:
        s3.delete_bucket(Bucket=b)
    except Exception:
        pass
PYEOF
python3 - <<'PYEOF' 2>/dev/null || true
import boto3
s3 = boto3.client("s3", region_name="us-east-1")
try:
    for b in s3.list_buckets().get("Buckets", []):
        n = b["Name"]
        if n.startswith("vera2-"):
            try:
                for o in s3.list_objects_v2(Bucket=n).get("Contents", []):
                    s3.delete_object(Bucket=n, Key=o["Key"])
                s3.delete_bucket(Bucket=n)
            except Exception:
                pass
except Exception:
    pass
try:
    for b in s3.list_directory_buckets().get("Buckets", []):
        if b["Name"].startswith("vera2-"):
            try:
                s3.delete_bucket(Bucket=b["Name"])
            except Exception:
                pass
except Exception:
    pass
PYEOF
echo "torn down: vera2- general-purpose and directory buckets"
