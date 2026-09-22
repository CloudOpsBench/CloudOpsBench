# CloudOpsBench

An open-source task suite for evaluating AI agents on cloud infrastructure operations.
Tasks are executed through [Harbor](https://harborframework.com/docs) against an isolated
AWS emulator. Verifiers check resulting cloud state, not plausible-looking code or an
agent's claim of success.

## Current tasks

| Task | Objective | Status |
|---|---|---|
| [`aws/tighten-sqs-redrive-allow-policy`](tasks/aws/tighten-sqs-redrive-allow-policy/instruction.md) | Tighten a dead-letter queue's redrive-allow policy to least privilege (Terraform) | Experimental |
| [`aws/promote-lambda-live-alias`](tasks/aws/promote-lambda-live-alias/instruction.md) | Publish a new Lambda build and cut the `live` alias over to it (Terraform) | Experimental |
| [`aws/tighten-kinesis-resource-policy`](tasks/aws/tighten-kinesis-resource-policy/instruction.md) | Tighten a Kinesis stream's resource policy to least privilege (Terraform) | Experimental |
| [`aws/decommission-analytics-environment`](tasks/aws/decommission-analytics-environment/instruction.md) | Fully remove a prefixed analytics environment and nothing else | Experimental |
| [`aws/decommission-data-pipeline`](tasks/aws/decommission-data-pipeline/instruction.md) | Fully remove a prefixed data pipeline and nothing else | Experimental |
| [`aws/decommission-event-workload`](tasks/aws/decommission-event-workload/instruction.md) | Fully remove a prefixed event-driven workload and nothing else | Experimental |

Every task starts from existing infrastructure: the task container seeds its starting cloud
state into the trial's fresh emulator before the agent is let in (see
[seeded tasks](docs/seeded-tasks.md)). Oracle **1** / nop **0** were checked against the
emulator outside Harbor; runs through the operator runner are still pending.
No model evaluations or leaderboard results have been published.

## How grading works

```text
Task instruction → agent → emulator APIs → resulting cloud state → verifier → 0 or 1
```

- **1:** required state exists.
- **0:** required state does not exist.
- **No valid reward:** verifier/setup error, reported separately.

Reference solutions change the cloud; verifiers independently read it back. The pipeline
itself was first proven with a since-retired S3 smoke task; see the
[recorded smoke evidence](docs/smoke-test.md#executed-smoke-evidence).
Emulator-support issue tracking is a separate runner concern and never rewrites rewards.

## Public content and private execution

This repository contains task instructions, container recipes, verifiers, reference
solutions, and documentation under the [MIT license](LICENSE).

The emulator and [CloudOpsBenchRunner](https://github.com/CloudOpsBench/CloudOpsBenchRunner)
are private. The runner injects the emulator image and dummy identity into each task and
uses Harbor for execution. **Cloning this public repository alone is not sufficient to
run cloud tasks.** No real AWS account or real cloud credentials should be supplied to
the task containers. Deployment instructions live in the private runner's `RUNNING.MD`.

The smoke integration targets **Harbor 0.21.0**. See [smoke-test notes](docs/smoke-test.md)
for the connection contract, execution procedure, and limitations. Shared-container grading
is used for trusted oracle/nop tests; untrusted model grading still needs isolation review.

## Creating tasks: reference solution convention

Follow the [task creation guide](docs/creating-tasks.md). Keep reference solutions split into:

```text
solution/
├── solve.sh     Harbor oracle entrypoint: endpoint guard and dummy credentials
└── golden.sh    Commands that actually solve the task
```

`solve.sh` must refuse endpoints other than the trial emulator, configure the dummy
identity, change to `/workspace`, and invoke `bash /solution/golden.sh`. Keep the actual
solution logic in `golden.sh` and propagate failures back to Harbor.

This is a valid Harbor layout: `solve.sh` is the standard oracle entrypoint and may call
helper scripts. The name `golden.sh` and this split are **CloudOpsBench conventions**, not
Harbor requirements. Neither script belongs in the agent image or workspace.

Reference solutions complete the task; they do not initialize it. Starting state belongs
in `environment/seed/setup.sh`, run by the container entrypoint before its readiness
health check passes. See [seeded tasks](docs/seeded-tasks.md).

## Repository layout

```text
tasks/aws/<task>/        One Harbor task per directory (see the table above)
docs/                    Task conventions, evaluation, roadmap
scripts/validate.py      Dependency-free static checks
.github/                 Contribution templates
```

Run static checks with Python 3.11+:

```bash
python3 scripts/validate.py
```

These checks do not execute Docker, Harbor, or the emulator. See [CONTRIBUTING.md](CONTRIBUTING.md),
[task specification](docs/task-specification.md), [architecture](docs/architecture.md),
and [evaluation](docs/evaluation.md).
