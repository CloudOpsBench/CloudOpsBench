#!/bin/bash
set -euo pipefail
python3 -I - <<'PY'
import os
import boto3
from botocore.config import Config

endpoint = os.environ.get("AWS_ENDPOINT_URL")
if endpoint != "http://127.0.0.1:5003":
    raise RuntimeError("Run through the isolated CloudOpsBench runner; refusing other endpoints")
s3 = boto3.client("s3", endpoint_url=endpoint, region_name="us-east-1",
                  aws_access_key_id="test", aws_secret_access_key="test",
                  config=Config(s3={"addressing_style": "path"}, connect_timeout=5,
                                read_timeout=5, retries={"max_attempts": 0}))
s3.create_bucket(Bucket="cloudopsbench-smoke")
print("Created cloudopsbench-smoke")
PY
