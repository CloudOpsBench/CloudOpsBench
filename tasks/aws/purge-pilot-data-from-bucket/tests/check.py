"""Check that none of the pilot's data remains in the bucket and the bucket still exists.

Passes when the bucket exists, holds no objects, and the seeded multipart upload is
no longer in progress. Parts of an in-progress upload are stored data that
`list-objects-v2` does not return, so `list-multipart-uploads` is checked as well.
"""
import boto3
import botocore
import checkkit as ck

seed = ck.seed()
R = seed["region"]
BUCKET = seed["bucket"]
UPLOAD_ID = seed["upload_id"]
UPLOAD_KEY = seed["upload_key"]

s3 = boto3.client("s3", region_name=R)

# The bucket itself must still exist.
try:
    s3.head_bucket(Bucket=BUCKET)
except botocore.exceptions.ClientError:
    ck.require(False, "the bucket %s is gone — another team is taking it over, so only the pilot's data "
                      "inside it was in scope." % BUCKET)

# The ordinary objects must be gone.
objs = []
for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
    objs += [o["Key"] for o in page.get("Contents", [])]
ck.require(not objs, "the bucket %s still holds objects (%s) — the pilot's data was not removed."
                     % (BUCKET, ", ".join(sorted(objs)[:3])))

# The seeded multipart upload must no longer be holding parts.
uploads = []
kw = {"Bucket": BUCKET}
while True:
    resp = s3.list_multipart_uploads(**kw)
    uploads += [(u["Key"], u["UploadId"]) for u in resp.get("Uploads", [])]
    if not resp.get("IsTruncated"):
        break
    kw["KeyMarker"] = resp.get("NextKeyMarker")
    kw["UploadIdMarker"] = resp.get("NextUploadIdMarker")

still = [u for u in uploads if u[1] == UPLOAD_ID]
msg = ""
if still:
    msg = (
        "the objects are gone, but the bucket is still storing the pilot's data: an in-progress multipart "
        "upload for '%s' never finished, and the parts already uploaded for it are still held — AWS only "
        "frees that storage once the upload is completed or stopped. `s3api list-objects-v2` does not return "
        "the parts of an in-progress upload, which is why the bucket reads as empty; "
        "`s3api list-multipart-uploads --bucket %s` shows it. Free it with `s3api abort-multipart-upload "
        "--bucket %s --key %s --upload-id %s`." % (UPLOAD_KEY, BUCKET, BUCKET, UPLOAD_KEY, UPLOAD_ID)
    )
ck.require(not still, msg)

ck.ok("none of the pilot's data is still stored in the bucket — the objects are gone and no in-progress "
      "multipart upload is holding parts; the bucket itself is intact")
