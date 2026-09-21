# Tighten an SQS redrive-allow policy

The vera-orders-dlq-us-east-1 dead-letter queue currently lets any queue in the account use it as a redrive target. Tighten its redrive-allow policy to least privilege so that the vera-orders-main-us-east-1 queue can still use it as a dead-letter target.

The Terraform managing these queues is in the workspace at `/workspace/workspaces/aws_task05/` — make the change there and apply.

## Environment

You are working against a dedicated AWS emulator, not real AWS. `AWS_ENDPOINT_URL`, dummy
credentials, and the home region `us-east-1` are already set in your environment, and the AWS
CLI, SDKs, and Terraform pick them up as they are. The account ID is `123456789012`.

AWS CLI v2, Python 3 with `boto3`, and Terraform 1.16.3 are installed. Terraform providers come from an offline mirror (hashicorp/aws 6.65.0); `terraform init` works without internet access and no other providers are available.

The Terraform workspace at `/workspace/workspaces/aws_task05/` is already initialised and the resources it manages are deployed.

Do not contact real AWS, use real credentials, install packages, or modify verifier files.
The task is graded on the resulting cloud state, not on what you report.
