"""Check that every vera2 S3 bucket has been deleted.

Passes when none of the seeded general-purpose buckets appear in list-buckets and none of
the seeded directory buckets appear in list-directory-buckets. A failed listing call
raises instead of being treated as an empty result.
"""
import boto3
import checkkit as ck

seed = ck.seed()
s3 = boto3.client("s3", region_name=seed["region"])

gen = {b["Name"] for b in s3.list_buckets().get("Buckets", [])}
try:
    dirb = {b["Name"] for b in s3.list_directory_buckets().get("Buckets", [])}
except Exception as error:
    raise RuntimeError(
        "could not enumerate S3 directory buckets, so the directory-bucket half of this task cannot be "
        "graded: %s" % error
    )

left = [b for b in seed["general_buckets"] if b in gen] + [b for b in seed["dir_buckets"] if b in dirb]

ck.require(
    not left,
    "Not all vera2 S3 buckets were deleted. `aws s3api list-buckets` (and `aws s3 ls`) returns only "
    "general-purpose buckets; S3 Express One Zone DIRECTORY buckets are omitted and require "
    "`aws s3api list-directory-buckets`. Still present: %s" % ", ".join(left),
)
ck.ok("all vera2 S3 buckets deleted (general-purpose and S3 Express directory)")
