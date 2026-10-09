"""Grade a lossless pilot-to-shared dataset consolidation."""
import hashlib

import boto3
import botocore
import checkkit as ck

seed = ck.seed()
region = seed["region"]
source = seed["source_bucket"]
destination = seed["shared_bucket"]
s3 = boto3.client("s3", region_name=region)


def require_bucket(bucket):
    try:
        s3.head_bucket(Bucket=bucket)
    except botocore.exceptions.ClientError:
        ck.require(False, f"required bucket {bucket} is missing; both buckets must remain")


def object_keys(bucket):
    keys = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        keys.extend(item["Key"] for item in page.get("Contents", []))
    return sorted(keys)


def multipart_uploads(bucket):
    uploads = []
    kwargs = {"Bucket": bucket}
    while True:
        response = s3.list_multipart_uploads(**kwargs)
        uploads.extend((item["Key"], item["UploadId"]) for item in response.get("Uploads", []))
        if not response.get("IsTruncated"):
            return uploads
        kwargs["KeyMarker"] = response["NextKeyMarker"]
        kwargs["UploadIdMarker"] = response["NextUploadIdMarker"]


def evidence(bucket, key):
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"]
    except botocore.exceptions.ClientError:
        return None
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
    return {"sha256": value.hexdigest(), "size": size}


require_bucket(source)
require_bucket(destination)

left_objects = object_keys(source)
ck.require(
    not left_objects,
    f"source bucket {source} still contains object(s): {', '.join(left_objects[:5])}",
)
left_uploads = multipart_uploads(source)
ck.require(
    not left_uploads,
    f"source bucket {source} still contains in-progress multipart data: "
    + ", ".join(key for key, _ in left_uploads[:5]),
)

expected = dict(seed["payloads"])
sentinel = seed["shared_sentinel"]
expected[sentinel["key"]] = {"sha256": sentinel["sha256"], "size": sentinel["size"]}
observed_keys = object_keys(destination)
ck.require(
    observed_keys == sorted(expected),
    f"shared bucket has the wrong key set; expected {sorted(expected)}, observed {observed_keys}",
)
for key, wanted in sorted(expected.items()):
    observed = evidence(destination, key)
    ck.require(observed is not None, f"shared bucket is missing {key}")
    ck.require(
        observed == wanted,
        f"payload integrity failed for {key}: expected {wanted}, observed {observed}",
    )

destination_uploads = multipart_uploads(destination)
ck.require(
    not destination_uploads,
    "shared bucket contains unfinished multipart data instead of only the completed dataset",
)

ck.ok(
    "pilot dataset was losslessly consolidated under the same keys, existing shared data was preserved, "
    "the source is empty, and both buckets remain"
)
