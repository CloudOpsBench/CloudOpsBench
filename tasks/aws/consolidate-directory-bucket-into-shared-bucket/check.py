"""Grade lossless consolidation from an S3 Express directory bucket into shared S3."""
import hashlib

import boto3
import botocore
import checkkit as ck


seed = ck.seed()
region = seed["region"]
source = seed["source_bucket"]
destination = seed["shared_bucket"]
control = seed["control_bucket"]
s3 = boto3.client("s3", region_name=region)


def require_bucket(bucket):
    try:
        s3.head_bucket(Bucket=bucket)
    except botocore.exceptions.ClientError:
        ck.require(False, f"required bucket {bucket} is missing; the task requires all buckets to remain")


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


for bucket in (source, destination, control):
    require_bucket(bucket)

source_keys = object_keys(source)
ck.require(
    not source_keys,
    f"pilot directory bucket {source} still contains object(s): {source_keys[:5]}",
)
left_uploads = multipart_uploads(source)
ck.require(
    not left_uploads,
    "pilot directory bucket still holds an in-progress multipart upload: "
    + ", ".join(key for key, _ in left_uploads[:5]),
)

expected = dict(seed["pilot_payloads"])
shared_sentinel = seed["shared_sentinel"]
expected[shared_sentinel["key"]] = {
    "sha256": shared_sentinel["sha256"],
    "size": shared_sentinel["size"],
}
actual_keys = object_keys(destination)
ck.require(
    actual_keys == sorted(expected),
    f"shared bucket key set is wrong; expected {sorted(expected)}, found {actual_keys}",
)
for key, wanted in sorted(expected.items()):
    observed = evidence(destination, key)
    ck.require(observed is not None, f"shared bucket is missing {key}")
    ck.require(observed == wanted, f"payload integrity failed for {key}: expected {wanted}, found {observed}")

ck.require(
    not multipart_uploads(destination),
    "shared bucket contains unfinished multipart state rather than only the completed pilot dataset",
)

control_sentinel = seed["control_sentinel"]
ck.require(
    object_keys(control) == [control_sentinel["key"]],
    f"unrelated control bucket {control} was modified",
)
ck.require(
    evidence(control, control_sentinel["key"])
    == {"sha256": control_sentinel["sha256"], "size": control_sentinel["size"]},
    "unrelated control data changed",
)

ck.ok(
    "the complete pilot dataset was copied with intact bytes into shared S3, the directory source is empty, "
    "both target buckets remain, and unrelated data is unchanged"
)
