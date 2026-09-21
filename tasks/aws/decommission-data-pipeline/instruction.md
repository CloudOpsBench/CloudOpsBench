# Decommission the data pipeline

The `adt-` data pipeline in AWS account 123456789012 has been deprecated and is still accruing cost. Shut it down completely — remove every resource that was provisioned for it (they all carry the `adt-` prefix in their names) so nothing of `adt-` survives. Do not modify or delete anything that isn't part of `adt-`.

## Environment

You are working against a dedicated AWS emulator, not real AWS. `AWS_ENDPOINT_URL`, dummy
credentials, and the home region `us-east-1` are already set in your environment, and the AWS
CLI, SDKs, and Terraform pick them up as they are. The account ID is `123456789012`.

AWS CLI v2 and Python 3 with `boto3` are installed. Terraform is not installed.

Your writable workspace is `/workspace`; it starts empty.

Do not contact real AWS, use real credentials, install packages, or modify verifier files.
The task is graded on the resulting cloud state, not on what you report.
