# Creating a task

Read the [specification](task-specification.md) first. Use unique IDs and paths under
`tasks/<provider>/<lowercase-hyphenated-objective>/`.

## Define the objective

State the workspace, permitted tools, initial state, desired resource properties, and
constraints in `instruction.md`. Do not hide scored requirements in tests. The secure S3
example requests Terraform provisioning, versioning, all four public-access blocks,
default SSE, and `Environment=production` on a fresh bucket.

## Build the Harbor package

Provide `instruction.md`, `task.toml`, `environment/Dockerfile`, `solution/solve.sh`, and
`tests/test.sh`. Set finite timeouts and distinguish Harbor configuration from project
metadata. `metadata.status` is informational, not an execution gate.

The secure S3 example now installs Terraform 1.16.3 (checksum verified), AWS provider
6.65.0 (checked-in Linux x86_64 lock file and offline mirror), AWS CLI 1.46.1, and boto3
1.43.31. The Python base image is digest-pinned. Transitive Python/apt dependencies are
not fully locked. Never copy solutions, verifiers, or private emulator code into the image.

The operator runner supplies a fresh emulator and phase-scoped egress control. Its endpoint
is `http://127.0.0.1:5003`, region `us-east-1`, credentials `test`/`test`, path-style S3.
Never inherit host credentials or permit real-cloud/metadata fallback. The secure task's
root-owned starter provider/lock live in a sticky `/workspace`; the non-root agent can
create resources/state files but cannot replace those starter files. Terraform runtime
initialization uses a local mirror with no direct registry fallback.

## Reference solution and verifier

`solution/solve.sh` copies the reference resources, initializes from the pinned lock/mirror,
validates, and applies. It must not write rewards or call verifier helpers.

The verifier independently reads emulator state with explicit dummy credentials and an
endpoint allowcheck. It checks bucket existence, versioning, public-access flags,
encryption, and tags—not a particular Terraform implementation. The shell writes reward
1 or 0 for semantic pass/fail; SDK/transport/authentication failures leave no reward and
are evaluation errors. Python runs with `-I`. Tests arrive only after agent execution.

Shared-container verification is **not** a tamper-proof grading boundary. Terraform
provenance also cannot be established from final cloud state alone.

## Validate before publishing results

Local checks (the verifier unit suite requires boto3, but never accesses AWS):

```bash
python3 scripts/validate.py
python3 scripts/test_secure_s3_verifier.py
bash -n tasks/aws/create-secure-s3-bucket/solution/solve.sh
bash -n tasks/aws/create-secure-s3-bucket/tests/test.sh
```

On a configured operator runner, use a pushed task revision:

```bash
uv run cobr run --tasks-ref "$TASKS_SHA" --task aws/create-secure-s3-bucket --harness oracle --seed 1 -k 1 -n 1 --no-upload
uv run cobr run --tasks-ref "$TASKS_SHA" --task aws/create-secure-s3-bucket --harness nop --seed 1 -k 1 -n 1 --no-upload
```

Require oracle 1 and nop 0 without evaluation errors. Check controlled wrong states
(versioning suspended, public-access flags false, wrong tags), repeat on fresh emulators,
and inspect cleanup. Missing encryption controls must respect the emulator's actual
representation of S3 defaults. Static/mocked tests alone are not execution evidence.

Before a release, also validate equivalent solutions, concurrency, model execution,
verifier integrity, egress isolation, error classification, and emulator API fidelity.
Record task SHA, emulator digest, tool/harness versions, seeds and budgets. Keep failed
attempts and evaluation errors visible; do not weaken semantic checks to make an oracle pass.
