"""Grader: exit 0 = PASS. Every vera2 S3 bucket must be deleted — general-purpose AND table buckets. `aws s3api
list-buckets` returns only general-purpose buckets; S3 TABLE buckets (GA Dec 2024) are a separate bucket type
in a separate CLI service, `aws s3tables list-table-buckets`, and are omitted by list-buckets (and by
list-directory-buckets). A solver that only clears list-buckets leaves the table bucket in place.
"""
import json
import subprocess
import time
import boto3
import checkkit as ck
seed = ck.seed()
s3 = boto3.client("s3", region_name=seed["region"])

def present():
    left = []
    # general-purpose bucket
    try:
        s3.head_bucket(Bucket=seed["gp_bucket"])
        left.append(seed["gp_bucket"])
    except Exception:
        pass
    # table buckets via the s3tables CLI (avoid boto3 service-model dependency)
    r = subprocess.run(
        ["aws", "s3tables", "list-table-buckets", "--region", seed["region"], "--output", "json"],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        arns = {t.get("arn") for t in json.loads(r.stdout or "{}").get("tableBuckets", [])}
        if seed["table_bucket_arn"] in arns:
            left.append(seed["table_bucket_arn"])
    else:
        left.append("s3tables-list-error:" + (r.stderr or "")[:80])
    return left

remaining = present()
if remaining:
    time.sleep(6)
    remaining = present()

ck.require(
    not remaining,
    "Not all vera2 S3 buckets deleted. `list-buckets` omits S3 TABLE buckets (separate bucket type + service, "
    "`aws s3tables list-table-buckets`). Still present: %s" % ", ".join(remaining),
)
ck.ok("all vera2 S3 buckets deleted (general-purpose and table buckets)")
