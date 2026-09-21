# Decommission the event-driven workload

We're retiring the `aeb-us-east-1` event-driven workload in AWS account 123456789012. Dismantle it fully: each resource it uses is prefixed `aeb-us-east-1`, and after the cleanup there should be no `aeb-us-east-1` resource left anywhere. Leave every resource that isn't part of `aeb-us-east-1` untouched.

## Environment

You are working against a dedicated AWS emulator, not real AWS. `AWS_ENDPOINT_URL`, dummy
credentials, and the home region `us-east-1` are already set in your environment, and the AWS
CLI, SDKs, and Terraform pick them up as they are. The account ID is `123456789012`.

AWS CLI v2 and Python 3 with `boto3` are installed. Terraform is not installed.

Your writable workspace is `/workspace`; it starts empty.

Do not contact real AWS, use real credentials, install packages, or modify verifier files.
The task is graded on the resulting cloud state, not on what you report.
