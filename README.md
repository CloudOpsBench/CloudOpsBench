# CloudOpsBench

An open-source task suite for evaluating AI agents on cloud infrastructure operations.
Tasks are executed through [Harbor](https://harborframework.com/docs) against an isolated
AWS emulator. Verifiers check resulting cloud state, not plausible-looking code or an
agent's claim of success.

## Current tasks

| Task | Objective | Status |
|---|---|---|
| [`aws/create-s3-bucket`](tasks/aws/create-s3-bucket/instruction.md) | Create one named S3 bucket using the Python AWS SDK | Oracle **1**, nop **0** verified on Harbor 0.21.0 |
| [`aws/create-secure-s3-bucket`](tasks/aws/create-secure-s3-bucket/instruction.md) | Use Terraform to create a private, encrypted, versioned bucket | Blocked scaffold; deliberately not runnable yet |

The first task deliberately has just **one requirement**: `cloudopsbench-smoke` exists.
It is a pipeline check, not a challenging benchmark or a claim of broad emulator fidelity.
No model evaluations or leaderboard results have been published.

## How grading works

```text
Task instruction → agent → emulator APIs → resulting cloud state → verifier → 0 or 1
```

- **1:** required state exists.
- **0:** required state does not exist.
- **No valid reward:** verifier/setup error, reported separately.

For the smoke task, the reference solution creates the bucket; the verifier independently
lists buckets. The oracle passed and the no-op agent failed as expected on fresh emulators; see the
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

## Repository layout

```text
tasks/aws/create-s3-bucket/         Minimal SDK smoke task
tasks/aws/create-secure-s3-bucket/  Blocked Terraform example
docs/                              Task conventions, evaluation, roadmap
scripts/validate.py                 Dependency-free static checks
.github/                           Contribution templates
```

Run static checks with Python 3.11+:

```bash
python3 scripts/validate.py
```

These checks do not execute Docker, Harbor, or the emulator. See [CONTRIBUTING.md](CONTRIBUTING.md),
[task specification](docs/task-specification.md), [architecture](docs/architecture.md),
and [evaluation](docs/evaluation.md).
