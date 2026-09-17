# Create a secure S3 bucket

Using Terraform, create an S3 bucket named `cloudopsbench-data` in the provided cloud emulator.

Requirements:

- Enable bucket versioning.
- Block public access: enable `BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, and `RestrictPublicBuckets` at bucket level.
- Enable default server-side encryption (SSE-S3 or SSE-KMS).
- Add the tag `Environment=production`.

Keep your Terraform configuration in `/workspace` and apply it, leaving the resulting bucket in place. Different valid Terraform implementations are acceptable. You may use the shell and, when provisioned, AWS CLI for inspection, but provisioning must use Terraform. Do not contact real AWS or use real cloud credentials.

The intended initial state is an empty, isolated emulator scope with no existing bucket named `cloudopsbench-data`. Connection configuration and emulator-only identity must be supplied by the environment, not invented by the agent.

**Scaffold status — not runnable:** emulator provisioning, connection configuration, tools, and deterministic initialization are TODO. The environment deliberately refuses to build until integration is complete. This note describes authoring status, not an instruction to bypass the guard.
