# S3 smoke task

`aws/create-s3-bucket` is intentionally tiny: create the S3 bucket
`cloudopsbench-smoke`. There are no tagging, versioning, encryption, or IaC requirements.
The older `create-secure-s3-bucket` task remains a blocked Terraform scaffold.

## Execution contract

- Harbor 0.21.0; Linux Docker environment.
- Python 3.12 agent image pinned by digest, with `boto3==1.43.31` installed at build time.
  Transitive Python dependencies are not yet locked; no runtime installation is needed.
- Fresh emulator process for every trial; dummy access key/secret `test`, region `us-east-1`.
- Runner-owned Compose defines `main` and `vera` without explicit networks. Harbor's
  egress-control sidecar places both in a per-trial shared network namespace. This preserves
  its TCP egress policy instead of bypassing it with a task-authored bridge network.
- `AWS_ENDPOINT_URL=http://127.0.0.1:5003`; S3 path-style addressing. Oracle and verifier
  refuse any other endpoint and use explicit dummy credentials, not the AWS credential chain.
- Agent user `agent`, root-owned tools, writable `/workspace`. Verifier user `root`.
- Tests and solution are not in the build context. Harbor uploads them at execution time.
- Shared verifier environment for these trusted smoke tests only. This is not a certification
  of tamper-resistant grading or network isolation against an adversarial agent.

## Procedure (operator runner required)

From the configured runner, use an exact pushed task commit for `TASKS_SHA`:

```bash
uv run cobr run --tasks-ref "$TASKS_SHA" --task aws/create-s3-bucket --harness oracle --seed 1 -k 1 -n 1 --no-upload
uv run cobr run --tasks-ref "$TASKS_SHA" --task aws/create-s3-bucket --harness nop --seed 1 -k 1 -n 1 --no-upload
```

Expected: oracle reward **1**, nop reward **0**, no evaluation errors. The verifier writes
no reward on endpoint/SDK/backend errors; Harbor must report those separately.

Run the oracle twice on fresh emulators to check reset/lifecycle behavior. Check teardown
and isolation before increasing concurrency or running a model. The task is not meant to
run directly through bare Harbor without the runner-injected emulator.

## Executed smoke evidence

Tested on **2026-09-17**, on the private runner with Harbor **0.21.0**:

- Task commit: `35f3333b92d54fb0867828b8e0b7ec5bd9a78469`.
- Emulator digest: `sha256:ccd587b81c3b54fa4f01aa0bd6b97f9f3df1d9e3c992c9461d27317eb0588a0a`.
- Oracle (`-k 1 -n 1`): **1/1 passed**, no evaluation errors.
- Nop (`-k 1 -n 1`): **0/1 passed**, reward **0**, no evaluation errors.
- Repeated oracle (`-k 2 -n 2`): **2/2 passed**, no evaluation errors.
- Harbor's trial containers were removed after completion. An unrelated manually started
  emulator smoke container was left untouched.

All tests used `--no-upload`. Artifacts remain on the private runner; these are pipeline
checks, not model leaderboard results. The concurrent test checks basic execution of two
fresh trials, not adversarial cross-trial access.

## Remaining gates

A real model run, separate trusted verifier, adversarial egress/tampering tests, provider
API allowlisting, broader emulator semantics, and fully locked image/dependency builds are
not implied by an oracle/nop smoke pass. The Terraform scaffold has additional independent
integration TODOs.
