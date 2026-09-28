# Creating or importing a task

Use the [task specification](task-specification.md) and [lifecycle contract](seeded-tasks.md).
The curated Harbor-style format is the only documented authoring path.

## 1. Preserve the task

Place the task under `tasks/aws/<task-id>/`. Keep `instruction.md`,
`environment/lifecycle/setup.sh`, its assets, `tests/check.py`, and `solution/solve.sh`
unchanged when importing an existing task. Retain optional lifecycle teardown scripts.

Do not weaken checks, skip unsupported operations, replace dynamic seed files with static
fixtures, or add emulator-specific expected results. Any genuine task defect should be
fixed transparently in the canonical task for all execution backends.

## 2. Declare dependencies and metadata

Include `task.toml`. The directory supplies the task ID when `metadata.id` is absent.
Set appropriate timeouts and record task metadata without embedding credentials.

A Dockerfile is optional when the runner's shared image supplies the required tools.
For additional dependencies, publish `environment/Dockerfile` with Python 3, boto3,
AWS CLI, bash, a non-root `agent` user, and the extra tools. Pin versions where possible.
The runner owns startup coordination; keep setup in the lifecycle script.

Do not supply a custom `tests/test.sh`, emulator Compose file, or solution endpoint wrapper.
The runner adds execution scaffolding to a copy, leaving the canonical task logic intact.

## 3. Validate

```bash
python3 scripts/validate.py
# Substitute the imported task's actual path.
bash -n tasks/aws/<task-id>/environment/lifecycle/setup.sh
bash -n tasks/aws/<task-id>/solution/solve.sh
```

Inspect the rendered package and verify that original script contents are unchanged.
Run oracle, nop, and deliberately incomplete fixes on fresh trials using the
[validation procedure](smoke-test.md). Check state preservation, collateral-change checks,
and equivalent valid solutions, not merely the reference solution's success.

## 4. Publish evidence, not assumptions

Record the exact task commit, runtime and emulator versions, Harbor version, timeouts,
attempt policy, and observed rewards/errors. Static checks and rendering are not proof
of execution or emulator fidelity. Review logs for sensitive content before publication.
See [evaluation](evaluation.md) and [CONTRIBUTING](../CONTRIBUTING.md).
