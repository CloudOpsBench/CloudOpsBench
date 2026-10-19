# Tighten a Kinesis resource policy

The vera-events-stream-<region> Kinesis data stream has a resource policy that lets anyone access it. Tighten it to least privilege so that only the events-producer application (IAM role vera-events-producer-<region>) can write to the stream.

The Terraform managing the stream is in the workspace at `$AGENT_WORKSPACE` — make the change there and apply.

## Environment

Use only the isolated AWS sandbox account and credentials supplied by the platform.
The home region is `$AWS_REGION`; `<region>` in resource names means its actual value.
Do not substitute a hard-coded account ID or use personal AWS credentials. AWS CLI v2
and Python 3 with boto3 are available. Work only on the task's resources.

The initialized Terraform project and its deployed state are in `$AGENT_WORKSPACE`.
Terraform providers are supplied by the platform's offline mirror. Use the installed
versions; do not download tools or providers from the internet.

Do not modify verifier files. Grading checks resulting cloud state, not your report.
