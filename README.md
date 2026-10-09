# CloudOpsBench

An open-source task suite for evaluating AI agents on cloud infrastructure operations.
Tasks define the initial cloud state, the agent's objective, and the checks for success.
One canonical task definition is used across execution backends; tests are not rewritten
for the emulator.

## Task format

The curated Harbor-style lifecycle layout is the only documented task contract:

```text
tasks/aws/<task-id>/
├── instruction.md
├── task.toml
├── environment/
│   ├── Dockerfile                 # optional tool-image override
│   └── lifecycle/
│       ├── setup.sh
│       ├── teardown.sh            # optional
│       └── assets/                # optional
├── tests/
│   └── check.py
└── solution/
    └── solve.sh
```

Publish the original instructions, setup, grader, assets, and reference solution.
The runner supplies execution scaffolding in a rendered copy: shared runtime dependencies,
startup coordination, endpoint/credential configuration, and the Harbor reward entrypoint.
Do not add emulator-only assertions, fixed dummy resource IDs, or endpoint guards to task
logic. See the [task specification](docs/task-specification.md) and
[lifecycle contract](docs/seeded-tasks.md).

The repository currently holds 45 tasks:

| Task | Objective |
|---|---|
| [`aws/clean-up-pricing-experiment`](tasks/aws/clean-up-pricing-experiment/instruction.md) | Remove a finished pricing experiment, including the query results it left in a shared bucket |
| [`aws/consolidate-directory-bucket-into-shared-bucket`](tasks/aws/consolidate-directory-bucket-into-shared-bucket/instruction.md) | Consolidate the dataset in a vera2 S3 Express One Zone directory bucket into the shared general-purpose bucket under the same keys and leave the directory bucket empty |
| [`aws/consolidate-pilot-bucket-into-shared-bucket`](tasks/aws/consolidate-pilot-bucket-into-shared-bucket/instruction.md) | Move a pilot dataset from its S3 bucket into the team's shared bucket under the same keys and leave the source bucket empty |
| [`aws/decommission-analytics-environment`](tasks/aws/decommission-analytics-environment/instruction.md) | Tear down a finished analytics environment by removing every resource named with its prefix |
| [`aws/decommission-customer-portal`](tasks/aws/decommission-customer-portal/instruction.md) | Remove everything belonging to the retired customer portal from the account while keeping the billing workload intact |
| [`aws/decommission-data-pipeline`](tasks/aws/decommission-data-pipeline/instruction.md) | Fully decommission the deprecated adt- data pipeline by removing every resource that carries its name prefix |
| [`aws/decommission-event-driven-workload`](tasks/aws/decommission-event-driven-workload/instruction.md) | Fully dismantle the retired `aeb-<region>` event-driven workload so that no resource with that prefix remains anywhere |
| [`aws/delete-decommissioned-s3-buckets`](tasks/aws/delete-decommissioned-s3-buckets/instruction.md) | Delete every vera2 S3 bucket in us-east-1 as part of decommissioning the project |
| [`aws/delete-pilot-ebs-volumes`](tasks/aws/delete-pilot-ebs-volumes/instruction.md) | Delete the retired vera2 pilot's EBS volumes and leave other teams' volumes alone |
| [`aws/delete-pilot-images`](tasks/aws/delete-pilot-images/instruction.md) | Delete the finished vera2 pilot's images so that no vera2- image remains in the account |
| [`aws/delete-project-acm-certificates`](tasks/aws/delete-project-acm-certificates/instruction.md) | Delete every vera2 ACM certificate in us-east-1 as part of decommissioning the project |
| [`aws/delete-project-queues`](tasks/aws/delete-project-queues/instruction.md) | Delete every queue belonging to the retired vera2 project so that no vera2- queue remains in the account |
| [`aws/delete-scratch-s3-buckets`](tasks/aws/delete-scratch-s3-buckets/instruction.md) | Empty and delete every vera2 S3 bucket in us-east-1 as part of shutting down the project |
| [`aws/deregister-pilot-machine-images`](tasks/aws/deregister-pilot-machine-images/instruction.md) | Deregister the retired vera2 pilot's machine images, leave other teams' images untouched, and report which images were deregistered |
| [`aws/disable-alarm-actions-for-maintenance`](tasks/aws/disable-alarm-actions-for-maintenance/instruction.md) | Disable alarm actions on all vera2 CloudWatch alarms ahead of a maintenance window |
| [`aws/enable-efs-automatic-backups`](tasks/aws/enable-efs-automatic-backups/instruction.md) | Enable automatic backups on the vera2 EFS file systems |
| [`aws/enable-tagged-eventbridge-rules`](tasks/aws/enable-tagged-eventbridge-rules/instruction.md) | Enable every EventBridge rule tagged App=intake and leave all other rules as they are |
| [`aws/finish-telemetry-archive-cutover`](tasks/aws/finish-telemetry-archive-cutover/instruction.md) | Finish a half-landed archive cutover so nothing writes to the retired bucket |
| [`aws/fix-cross-vpc-database-connectivity`](tasks/aws/fix-cross-vpc-database-connectivity/instruction.md) | Fix app servers in prod-vpc timing out when connecting to the database in shared-vpc |
| [`aws/lower-order-error-alarm-threshold`](tasks/aws/lower-order-error-alarm-threshold/instruction.md) | Lower a CloudWatch order-error alarm's threshold from 1000 to 100 so it pages on-call earlier |
| [`aws/promote-lambda-live-alias`](tasks/aws/promote-lambda-live-alias/instruction.md) | Roll out a Lambda build while preserving its consumer |
| [`aws/purge-pilot-data-from-bucket`](tasks/aws/purge-pilot-data-from-bucket/instruction.md) | Delete the vera2 pilot's data from its S3 bucket while leaving the bucket itself in place |
| [`aws/reconnect-tagged-alarms-to-sns-topic`](tasks/aws/reconnect-tagged-alarms-to-sns-topic/instruction.md) | Wire tagged CloudWatch alarms back to their SNS notification topic |
| [`aws/remove-deleted-role-references`](tasks/aws/remove-deleted-role-references/instruction.md) | Stop anything in the account from naming a deleted IAM role, without re-creating the role |
| [`aws/remove-external-access-from-resource-policies`](tasks/aws/remove-external-access-from-resource-policies/instruction.md) | Remove access granted to principals outside the account from the resource-based policies of every vera2 resource in us-east-1 |
| [`aws/repair-batch-settlement-workflow`](tasks/aws/repair-batch-settlement-workflow/instruction.md) | Repair the batch-settlement Step Functions workflow in place, publish two repaired versions, and route the live and audit aliases to different repaired versions |
| [`aws/repair-dynamodb-stream-poison-pill-consumer`](tasks/aws/repair-dynamodb-stream-poison-pill-consumer/instruction.md) | Repair a revisioned DynamoDB Streams consumer with atomic projection/receipts and all-or-none cross-entity transaction envelopes |
| [`aws/repair-evidence-event-routing`](tasks/aws/repair-evidence-event-routing/instruction.md) | Repair a compliance evidence pipeline that has silently captured nothing, across every source that feeds it |
| [`aws/repair-lambda-canary-rollback-guardrail`](tasks/aws/repair-lambda-canary-rollback-guardrail/instruction.md) | Repair a Lambda canary deployment guardrail in place so the live alias, CodeDeploy deployment group, error alarm, and CodeDeploy role match the required secure rollback profile |
| [`aws/repair-urgent-order-alert-delivery`](tasks/aws/repair-urgent-order-alert-delivery/instruction.md) | Find and fix every reason urgent order events published to an SNS topic are not reaching the on-call SQS queue |
| [`aws/repoint-checkout-database-endpoint`](tasks/aws/repoint-checkout-database-endpoint/instruction.md) | Update the Parameter Store configuration so the vera2 checkout service uses the new database endpoint |
| [`aws/restore-audit-log-relay-coverage`](tasks/aws/restore-audit-log-relay-coverage/instruction.md) | Restore full audit relay coverage across a fleet of application log groups |
| [`aws/restore-backup-plan-coverage`](tasks/aws/restore-backup-plan-coverage/instruction.md) | Restore AWS Backup plan coverage for a tagged resource fleet that has no recovery points, while ensuring the plan does not back up its scratch bucket |
| [`aws/restore-dynamodb-write-autoscaling`](tasks/aws/restore-dynamodb-write-autoscaling/instruction.md) | Fix a provisioned DynamoDB table whose write capacity is stuck at 2 so that it auto-scales between 2 and 10 going forward |
| [`aws/restore-ecr-image-scan-coverage`](tasks/aws/restore-ecr-image-scan-coverage/instruction.md) | Restore vulnerability scanning coverage across a container registry |
| [`aws/restore-encrypted-bucket-read-access`](tasks/aws/restore-encrypted-bucket-read-access/instruction.md) | Diagnose why an application role gets AccessDenied reading the reports data bucket and restore its read access within the security team's constraints |
| [`aws/restrict-vendor-session-table-access`](tasks/aws/restrict-vendor-session-table-access/instruction.md) | Cut an external vendor's sessions off from a reclassified DynamoDB table across every integration path |
| [`aws/retire-shared-automation-role`](tasks/aws/retire-shared-automation-role/instruction.md) | Migrate everything that operates through a legacy shared automation role onto its replacement role, remove every remaining reference to the legacy role, and delete it |
| [`aws/revoke-external-access-metrics-collector`](tasks/aws/revoke-external-access-metrics-collector/instruction.md) | Find every vera2 resource that parties outside the account can reach and narrow each one so that only the account retains access |
| [`aws/revoke-external-access-subsidiary-workspace`](tasks/aws/revoke-external-access-subsidiary-workspace/instruction.md) | Close every remaining outside-the-account share left behind by a subsidiary workspace |
| [`aws/revoke-external-access-trial-integration`](tasks/aws/revoke-external-access-trial-integration/instruction.md) | Find every resource of a trial integration being retired that is reachable from outside the account and restrict it to the account |
| [`aws/rotate-exposed-webhook-signing-key`](tasks/aws/rotate-exposed-webhook-signing-key/instruction.md) | Replace an exposed vendor webhook signing key and stop the old value resolving anywhere |
| [`aws/route-meter-exports-to-analytics-table`](tasks/aws/route-meter-exports-to-analytics-table/instruction.md) | Route every meter interval exporter into the dataset the analytics table reads |
| [`aws/tighten-kinesis-resource-policy`](tasks/aws/tighten-kinesis-resource-policy/instruction.md) | Restrict stream access while preserving legitimate producer/consumer access |
| [`aws/tighten-sqs-redrive-allow-policy`](tasks/aws/tighten-sqs-redrive-allow-policy/instruction.md) | Restrict dead-letter queue sources without breaking existing dependencies |

Three tasks (`promote-lambda-live-alias`, `tighten-kinesis-resource-policy`,
`tighten-sqs-redrive-allow-policy`) use Terraform. They require the platform to provide
`AGENT_WORKSPACE`, Terraform, and an offline provider mirror.

Setup, grader, and solution scripts were imported without behavioral changes. Source import
and static validity do not imply that a task is executable end-to-end: the 42 most recently
added tasks have not yet been run with oracle and negative controls. No task ships an
agent permission policy: the runner gives the agent the same identity as setup and the
grader.

## Execution and grading

```text
Canonical task → runner rendering → setup → agent → unchanged grader → reward
```

- **1:** the grader passes.
- **0:** the grader explicitly fails.
- **No valid reward:** setup or verifier execution error.

The private [CloudOpsBenchRunner](https://github.com/CloudOpsBench/CloudOpsBenchRunner)
currently executes tasks through Harbor 0.21.0 against a private AWS emulator. It supplies
dummy credentials and an isolated emulator per trial. An AWS harness can consume the
same task logic with scoped AWS credentials and cleanup; real-AWS orchestration is not
implemented in this runner. Cloning this repository alone does not provide an execution
backend. Never supply real credentials to emulator task containers.

Rendering, Compose configuration, and Harbor metadata were checked for the ten curated
exports. Full Docker/Harbor lifecycle execution and adversarial isolation validation remain
release gates. No benchmark results are implied by those packaging checks.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md), [creating tasks](docs/creating-tasks.md),
[architecture](docs/architecture.md), and [evaluation](docs/evaluation.md).

Run static checks with Python 3.11+:

```bash
python3 scripts/validate.py
```

Static checks are not execution tests. See the [validation procedure](docs/smoke-test.md)
and [roadmap](docs/roadmap.md). Public content is under the [Apache License 2.0](LICENSE).
