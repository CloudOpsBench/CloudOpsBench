We're retiring the `aeb-<region>` event-driven workload in AWS account <account-id>. Dismantle it fully: each resource it uses is prefixed `aeb-<region>`, and after the cleanup there should be no `aeb-<region>` resource left anywhere. Leave every resource that isn't part of `aeb-<region>` untouched.

`<account-id>` is the ID of the AWS account you are working in, and `<region>` is the value of `$AWS_REGION`.
