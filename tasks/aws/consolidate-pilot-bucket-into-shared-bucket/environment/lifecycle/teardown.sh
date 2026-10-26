#!/usr/bin/env bash
# Aborts multipart uploads, empties and deletes the two buckets recorded in
# seed_state.json.
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"

# setup.sh records the exact scope before creating either bucket. Never sweep unrelated vera2-* resources.
python3 - "$REGION" <<'PY'
import json
import os
import sys

import boto3
import botocore

region = sys.argv[1]
if not os.path.exists("seed_state.json"):
    print("no seed state; nothing to tear down")
    raise SystemExit(0)

state = json.load(open("seed_state.json"))
buckets = [state.get("source_bucket"), state.get("shared_bucket")]
if not all(isinstance(bucket, str) and bucket.startswith("vera2-") for bucket in buckets):
    raise SystemExit("refusing teardown: seed_state.json does not contain two scoped vera2- bucket names")

s3 = boto3.client("s3", region_name=state.get("region", region))
for bucket in buckets:
    try:
        s3.head_bucket(Bucket=bucket)
    except botocore.exceptions.ClientError:
        continue

    kwargs = {"Bucket": bucket}
    while True:
        response = s3.list_multipart_uploads(**kwargs)
        for upload in response.get("Uploads", []):
            s3.abort_multipart_upload(
                Bucket=bucket,
                Key=upload["Key"],
                UploadId=upload["UploadId"],
            )
        if not response.get("IsTruncated"):
            break
        kwargs["KeyMarker"] = response["NextKeyMarker"]
        kwargs["UploadIdMarker"] = response["NextUploadIdMarker"]

    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        keys = [{"Key": item["Key"]} for item in page.get("Contents", [])]
        if keys:
            s3.delete_objects(Bucket=bucket, Delete={"Objects": keys, "Quiet": True})
    s3.delete_bucket(Bucket=bucket)

print("torn down the exact pilot and shared buckets recorded by setup")
PY
