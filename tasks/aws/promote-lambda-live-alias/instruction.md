# Roll out a new Lambda build

We shipped a new build of the order-processor Lambda (vera-order-processor-us-east-1). The new handler is in index.py. Roll it out: publish the new code and cut the `live` alias over to it so production runs the new version.

The Terraform managing the function is in the workspace at `/workspace/workspaces/aws_task12/` — make the change there and apply.

## Environment

You are working against a dedicated AWS emulator, not real AWS. `AWS_ENDPOINT_URL`, dummy
credentials, and the home region `us-east-1` are already set in your environment, and the AWS
CLI, SDKs, and Terraform pick them up as they are. The account ID is `123456789012`.

AWS CLI v2, Python 3 with `boto3`, and Terraform 1.16.3 are installed. Terraform providers come from an offline mirror (hashicorp/aws 6.65.0, hashicorp/archive 2.8.1); `terraform init` works without internet access and no other providers are available.

The Terraform workspace at `/workspace/workspaces/aws_task12/` is already initialised and the resources it manages are deployed.

Do not contact real AWS, use real credentials, install packages, or modify verifier files.
The task is graded on the resulting cloud state, not on what you report.
