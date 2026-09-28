# Task specification

## Canonical Harbor-style source

The curated lifecycle layout is the sole documented task format:

```text
<task>/
├── instruction.md
├── task.toml
├── environment/
│   ├── Dockerfile                 # optional; runner has a shared default
│   └── lifecycle/
│       ├── setup.sh
│       ├── teardown.sh            # optional
│       └── assets/                # optional
├── tests/check.py
└── solution/solve.sh
```

Preserve existing setup, grader, solution, and asset contents when importing a task.
Do not adapt assertions or expected results to emulator behavior. Fix task defects as
explicit, versioned changes shared by all backends, not private compatibility patches.

## Metadata

- Place tasks under `tasks/aws/<task-id>/`; the relative path is the task ID.
- `metadata.id` is optional for lifecycle exports. If supplied, it must match the path.
- `[task].name` identifies the source task. The runner prefixes an unqualified name with
  `cloudopsbench/` in the rendered copy to satisfy Harbor's `org/name` requirement.
- Use `[metadata]` for descriptions and curation information.
- Configure task-appropriate `[agent].timeout_sec`, `[verifier].timeout_sec`, and
  `[environment].build_timeout_sec`. Calibrate budgets before publishing results.

## Source vs. rendered package

Source exports depend on the runner's runtime contract. They are not standalone upstream
Harbor packages until rendered. The runner supplies `tests/test.sh`, runtime helpers,
Compose configuration, and execution metadata for Harbor 0.21.0. Do not author a competing
`tests/test.sh` for this adapter; it rejects conflicting verifier entrypoints.

A Dockerfile may supply additional tools. It must provide Python 3, boto3, AWS CLI, bash,
and a non-root `agent` user. The runner owns the final entrypoint, user, working directory,
and readiness coordination. Put task setup in `environment/lifecycle/setup.sh`, not in a
custom image entrypoint. Do not copy tests or solutions into the agent image.

## Lifecycle and scoring

Setup runs before the agent. Setup and the unchanged grader share a protected runspace,
including the actual generated `seed_state.json`. The runner supplies `TASK_STATE_DIR`;
the agent uses a separate `/workspace`. See [seeded tasks](seeded-tasks.md) for details
and limitations on agent-visible generated files.

The grader uses normal AWS CLI/boto3 calls or the shared `checkkit` helpers. Endpoint
routing and credentials are backend configuration, not task logic. An explicit successful
exit maps to reward 1; explicit exit 1 maps to reward 0. Uncaught Python exceptions or
other exit codes are evaluation errors. The generated shell wrapper emits Harbor's
`/logs/verifier/reward.txt`; the original grader need not know that path.

## Release requirements

- Clear objective and constraints, with grading consistent with the instruction.
- Reproducible starting state and isolated per-trial resources.
- Reference solution and negative controls tested on fresh trials.
- Equivalent valid solutions accepted by the same grader.
- Recorded task/runtime/emulator versions, timeouts, and attempt policy.
- Reviewed credential, seed-state, verifier, and reward isolation.

Static validity, successful rendering, or an oracle pass alone is not benchmark readiness.
See [evaluation](evaluation.md) and [validation](smoke-test.md).
