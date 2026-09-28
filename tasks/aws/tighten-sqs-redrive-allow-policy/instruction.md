# Tighten an SQS redrive-allow policy

The vera-orders-dlq-<region> dead-letter queue currently lets any queue in the account use it as a redrive target. Tighten its redrive-allow policy to least privilege so that the vera-orders-main-<region> queue can still use it as a dead-letter target.

The Terraform managing these queues is in the workspace at `$AGENT_WORKSPACE` — make the change there and apply.

## Environment

Use only the isolated AWS sandbox account and credentials supplied by the platform.
The home region is `$AWS_REGION`; `<region>` in resource names means its actual value.
Do not substitute a hard-coded account ID or use personal AWS credentials. AWS CLI v2
and Python 3 with boto3 are available. Work only on the task's resources.

The initialized Terraform project and its deployed state are in `$AGENT_WORKSPACE`.
Terraform providers are supplied by the platform's offline mirror. Use the installed
versions; do not download tools or providers from the internet.

Do not modify verifier files. Grading checks resulting cloud state, not your report.
