# Task lifecycle

Use the [canonical Harbor-style layout](task-specification.md). Setup, tests, and reference
solutions stay backend-neutral and are published without emulator-specific rewrites.

## Setup

`environment/lifecycle/setup.sh` creates the initial cloud state. Optional assets remain
beside it under `environment/lifecycle/assets/`. Setup runs once per fresh trial, before
the agent can act. Failed or incomplete setup is an environment error, not a scored attempt.

The runner executes setup in a private runspace and sets `TASK_STATE_DIR` to that directory.
Relative state files, including dynamically generated `seed_state.json`, remain there for
the grader. Do not replace generated resource identifiers with checked-in seed fixtures.

The setup service remains alive for any background helpers. Restarting a partially seeded
trial is rejected; use a fresh trial instead.

## Agent and verifier

The agent runs as the non-root `agent` user in `/workspace`. It must discover the cloud
resources specified by the task rather than read private setup state.

Harbor uploads `tests/` for verification. The runner executes the unchanged `tests/check.py`
as root in the same private working directory used by setup. `checkkit` provides the helper
API used by the curated exports: `region`, `account_id`, `client`, `resource`, `seed`,
`as_list`, `require`, `fail`, and `ok`.

Setup, agent, and grader address the same cloud scope. The runner supplies credentials
and endpoint routing. The task does not hardcode emulator endpoints or dummy identity.
Reference solutions remain in `solution/solve.sh`; no extra solution wrapper is required.

## Cleanup and boundaries

`environment/lifecycle/teardown.sh`, when present, remains part of the canonical task for
AWS cleanup. Emulator trials discard their emulator and per-trial state instead of invoking
cloud teardown. The current runner implements emulator execution only, not real-AWS account
provisioning or cleanup orchestration.

The runtime does not automatically expose setup-generated local files to the agent.
Tasks requiring agent-visible files, additional helper APIs, or custom service topologies
need explicit runtime integration without changing grader semantics.

Root-only state and a non-root agent provide separation, but shared-container grading is
not a certified trusted boundary. End-to-end lifecycle, cleanup, and adversarial isolation
checks remain required before publishing results. See [validation](smoke-test.md).
