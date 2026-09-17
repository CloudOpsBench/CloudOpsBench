# Create one S3 bucket

Create an S3 bucket named **`cloudopsbench-smoke`** in `us-east-1` using the provided
AWS emulator. The task succeeds when this bucket exists in the emulator.

You start with an empty, dedicated emulator. Python 3 and the `boto3` AWS SDK are
installed. You may use Python; Terraform and AWS CLI are not required or installed.
Your writable workspace is `/workspace`.

Use `AWS_ENDPOINT_URL` and the dummy AWS credentials supplied in your environment.
Configure S3 path-style addressing. Do not contact real AWS, use real credentials,
install packages, or modify verifier files. There are no encryption, tagging, or
versioning requirements for this smoke test.
