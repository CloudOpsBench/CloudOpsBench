#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"

python3 - "$REGION" <<'PY'
import hashlib
import sys

import boto3

region = sys.argv[1]
s3 = boto3.client("s3", region_name=region)
names = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]
sources = sorted(n for n in names if n.startswith("vera2-") and n.endswith("-pilot"))
destinations = sorted(n for n in names if n.startswith("vera2-") and n.endswith("-shared"))
if len(sources) != 1 or len(destinations) != 1:
    raise SystemExit(
        "expected exactly one vera2-*-pilot and one vera2-*-shared bucket; "
        f"found {len(sources)} source(s) and {len(destinations)} destination(s)"
    )
source, destination = sources[0], destinations[0]


def multipart_uploads(bucket):
    kwargs = {"Bucket": bucket}
    while True:
        response = s3.list_multipart_uploads(**kwargs)
        yield from response.get("Uploads", [])
        if not response.get("IsTruncated"):
            return
        kwargs["KeyMarker"] = response["NextKeyMarker"]
        kwargs["UploadIdMarker"] = response["NextUploadIdMarker"]


def uploaded_parts(bucket, key, upload_id):
    kwargs = {"Bucket": bucket, "Key": key, "UploadId": upload_id}
    parts = []
    while True:
        response = s3.list_parts(**kwargs)
        parts.extend(
            {"ETag": part["ETag"], "PartNumber": part["PartNumber"]}
            for part in response.get("Parts", [])
        )
        if not response.get("IsTruncated"):
            return parts
        kwargs["PartNumberMarker"] = response["NextPartNumberMarker"]


def objects(bucket):
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        yield from page.get("Contents", [])


def digest(bucket, key):
    body = s3.get_object(Bucket=bucket, Key=key)["Body"]
    value = hashlib.sha256()
    size = 0
    try:
        while True:
            chunk = body.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            value.update(chunk)
    finally:
        body.close()
    return size, value.hexdigest()


uploads = list(multipart_uploads(source))
for upload in uploads:
    key, upload_id = upload["Key"], upload["UploadId"]
    parts = uploaded_parts(source, key, upload_id)
    if not parts:
        raise RuntimeError(f"multipart upload {key!r} has no uploaded parts to recover")
    s3.complete_multipart_upload(
        Bucket=source,
        Key=key,
        UploadId=upload_id,
        MultipartUpload={"Parts": parts},
    )

# Copy first, verify the complete bytes at the destination, and only then remove the source object.
for item in list(objects(source)):
    key = item["Key"]
    expected = digest(source, key)
    s3.copy_object(
        Bucket=destination,
        Key=key,
        CopySource={"Bucket": source, "Key": key},
        MetadataDirective="COPY",
    )
    observed = digest(destination, key)
    if observed != expected:
        raise RuntimeError(
            f"destination verification failed for {key!r}: expected {expected}, observed {observed}"
        )
    s3.delete_object(Bucket=source, Key=key)

if list(objects(source)) or list(multipart_uploads(source)):
    raise RuntimeError("source bucket is not empty after consolidation")

print(
    f"consolidated {len(uploads)} recovered multipart payload(s) and the complete pilot dataset "
    f"from {source} into {destination}"
)
PY
