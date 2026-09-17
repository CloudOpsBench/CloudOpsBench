"""Binary state check. Exceptions are evaluation errors, never fabricated zeroes."""
import os
import sys

import boto3
from botocore.config import Config


def verify(s3):
    names = {bucket["Name"] for bucket in s3.list_buckets()["Buckets"]}
    return "cloudopsbench-smoke" in names


def main():
    try:
        endpoint = os.environ.get("AWS_ENDPOINT_URL")
        if endpoint != "http://127.0.0.1:5003":
            raise RuntimeError("trusted emulator endpoint is missing or unexpected")
        # Explicit dummy identity: never fall back to metadata or local AWS profiles.
        s3 = boto3.client("s3", endpoint_url=endpoint, region_name="us-east-1",
                          aws_access_key_id="test", aws_secret_access_key="test",
                          config=Config(s3={"addressing_style": "path"}, connect_timeout=5,
                                        read_timeout=5, retries={"max_attempts": 0}))
        passed = verify(s3)
    except Exception as error:
        print(f"EVALUATION ERROR: {error}", file=sys.stderr)
        return 2
    print("PASS: bucket exists" if passed else "FAIL: required bucket is absent")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
