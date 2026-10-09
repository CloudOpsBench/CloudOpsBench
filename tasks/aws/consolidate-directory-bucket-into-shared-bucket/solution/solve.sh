#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"

python3 - "$REGION" <<'PY'
import hashlib
import sys

import boto3

region = sys.argv[1]
s3 = boto3.client("s3", region_name=region)


def directory_names():
    return [item["Name"] for item in s3.list_directory_buckets().get("Buckets", [])]


def location(name):
    value = s3.get_bucket_location(Bucket=name).get("LocationConstraint")
    return "us-east-1" if value is None else value


sources = sorted(
    name
    for name in directory_names()
    if name.startswith("vera2-") and name.endswith("-pilot--use1-az4--x-s3")
)
destinations = sorted(
    name
    for name in (item["Name"] for item in s3.list_buckets().get("Buckets", []))
    if name.startswith("vera2-") and name.endswith("-shared") and location(name) == region
)
if len(sources) != 1 or len(destinations) != 1:
    raise SystemExit(
        "expected exactly one vera2 S3 Express pilot bucket and one shared destination; "
        f"found {sources!r} and {destinations!r}"
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
        raise RuntimeError(f"multipart upload {key!r} has no uploaded data to consolidate")
    s3.complete_multipart_upload(
        Bucket=source,
        Key=key,
        UploadId=upload_id,
        MultipartUpload={"Parts": parts},
    )

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
    raise RuntimeError("pilot directory bucket is not empty after consolidation")

print(f"losslessly consolidated {len(uploads)} recovered multipart payload(s) from {source} into {destination}")
PY
