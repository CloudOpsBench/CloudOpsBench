# Decommission the analytics environment

Tear down the `aaq-7c21` analytics environment in AWS account 123456789012; the work is finished and we don't want to keep paying for it. Remove every resource belonging to it — they're all named with the `aaq-7c21` prefix — leaving no trace. Resources that aren't part of `aaq-7c21` should remain as they are.

## Environment

You are working against a dedicated AWS emulator, not real AWS. `AWS_ENDPOINT_URL`, dummy
credentials, and the home region `us-east-1` are already set in your environment, and the AWS
CLI, SDKs, and Terraform pick them up as they are. The account ID is `123456789012`.

AWS CLI v2 and Python 3 with `boto3` are installed. Terraform is not installed.

Your writable workspace is `/workspace`; it starts empty.

Do not contact real AWS, use real credentials, install packages, or modify verifier files.
The task is graded on the resulting cloud state, not on what you report.
