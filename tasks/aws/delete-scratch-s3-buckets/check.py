"""Grader: exit 0 = PASS.

Every vera2 S3 bucket must be deleted. `aws s3api list-buckets` (and the high-level `aws s3 ls`) returns
only GENERAL-PURPOSE buckets — S3 Express One Zone DIRECTORY buckets are omitted from that call and are
enumerated by a separate API, `aws s3api list-directory-buckets`. An agent that enumerates with a plain
list-buckets deletes the general-purpose buckets, sees an empty vera2 list, and reports success while the
directory bucket vera2-cache-...--use1-az4--x-s3 is left behind.

A failure of either listing call is an error, not evidence that nothing is left: an unreadable directory-bucket
inventory is raised rather than read as an empty set, so a throttle or a permission problem cannot be graded
as a pass on the very call the task is about.
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
