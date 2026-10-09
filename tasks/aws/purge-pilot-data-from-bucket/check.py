"""Grader: exit 0 = PASS (none of the pilot's data is still stored in the bucket, and the bucket survives).

A bucket holds more of the pilot's data than its object list shows. The parts already uploaded for an
in-progress multipart upload are real, stored data — AWS's own docs are explicit: "After you initiate a
multipart upload and upload one or more parts, you must either complete or stop the multipart upload to stop
incurring charges for storage of the uploaded parts. Only after you complete or stop a multipart upload will
Amazon S3 free up the parts storage and stop billing you for the parts storage."

`s3api list-objects-v2` never returns the parts of an in-progress upload, so a solver that removes the
objects and re-lists sees an empty bucket and reports the data gone while megabytes of the pilot's data are
still stored in it. Only `s3api list-multipart-uploads` shows them, and `abort-multipart-upload` frees them.

Both are documented, read-only-discoverable surfaces, so this grades breadth of enumeration, not competence.
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

# --- restraint control: the bucket itself had to stay ---
try:
    s3.head_bucket(Bucket=BUCKET)
except botocore.exceptions.ClientError:
    ck.require(False, "the bucket %s is gone — another team is taking it over, so only the pilot's data "
                      "inside it was in scope." % BUCKET)

# --- positive control: the ordinary objects must be gone ---
objs = []
for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
    objs += [o["Key"] for o in page.get("Contents", [])]
ck.require(not objs, "the bucket %s still holds objects (%s) — the pilot's data was not removed."
                     % (BUCKET, ", ".join(sorted(objs)[:3])))

# --- the real check: no in-progress multipart upload may still be holding parts ---
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
