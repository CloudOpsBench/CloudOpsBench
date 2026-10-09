#!/usr/bin/env bash
set -euo pipefail

if [ ! -f seed_state.json ]; then
  echo "no seed state; no scoped resources to tear down"
  exit 0
fi

python3 <<'PY'
import json

import boto3
import botocore


state = json.load(open("seed_state.json"))
region = state.get("region", "us-east-1")
buckets = [
    state.get("source_bucket"),
    state.get("shared_bucket"),
    state.get("control_bucket"),
]
if not all(isinstance(bucket, str) and bucket.startswith("vera2-") for bucket in buckets):
    raise SystemExit("refusing teardown: seed state does not contain three scoped vera2 bucket names")

s3 = boto3.client("s3", region_name=region)


def purge(bucket):
    try:
        s3.head_bucket(Bucket=bucket)
    except botocore.exceptions.ClientError:
        return

    kwargs = {"Bucket": bucket}
    while True:
        response = s3.list_multipart_uploads(**kwargs)
        for upload in response.get("Uploads", []):
            s3.abort_multipart_upload(Bucket=bucket, Key=upload["Key"], UploadId=upload["UploadId"])
        if not response.get("IsTruncated"):
            break
        kwargs["KeyMarker"] = response["NextKeyMarker"]
        kwargs["UploadIdMarker"] = response["NextUploadIdMarker"]

    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for item in page.get("Contents", []):
            s3.delete_object(Bucket=bucket, Key=item["Key"])

    last_error = None
    for _ in range(8):
        try:
            s3.delete_bucket(Bucket=bucket)
            return
        except botocore.exceptions.ClientError as error:
            if error.response.get("Error", {}).get("Code") == "NoSuchBucket":
                return
            last_error = error
    if last_error:
        raise last_error


for bucket in buckets:
    purge(bucket)

print("torn down exactly the directory source, shared destination, and control bucket recorded by setup")
PY
