# Seeded tasks

Operations tasks start from infrastructure that already exists: a queue with a policy to
tighten, a function to roll out, a stack to decommission. Harbor has no pre-agent hook that
can reach the runner's emulator sidecar, so each task seeds its own starting state.

## Layout

```text
<task>/
├── environment/
│   ├── Dockerfile
│   ├── entrypoint.sh        Runs the seed once, removes it, then marks the container ready
│   ├── seed/setup.sh        Builds the starting cloud state (and any Terraform workspace)
│   └── terraform/           Pinned providers + lock file for the offline mirror (if used)
├── solution/
│   ├── solve.sh             Endpoint guard, then golden.sh
│   └── golden.sh            Reference solution
└── tests/
    ├── test.sh              Writes reward 1/0; any other exit is an evaluation error
    ├── test_infra.py        Endpoint guard and emulator preflight, then runs check.py
    ├── check.py             State grader: exit 0 = pass, exit 1 = fail
    └── seed_state.json      Grader ground truth (only where check.py needs it)
```

## Contract

- **Ordering.** The runner starts the task container only after the emulator is healthy.
  `entrypoint.sh` runs `seed/setup.sh` as the `agent` user and then creates
  `/run/cloudopsbench/ready`. Both the Docker `HEALTHCHECK` and `[environment.healthcheck]`
  in `task.toml` wait for that file, so the agent never sees a half-seeded cloud.
- **Failure.** If seeding fails the container exits. The trial is an environment error, not
  a scored attempt.
- **What the agent can see.** The seed often creates resources the agent is meant to
  discover. The entrypoint deletes `seed/` before marking the container ready, writes seed
  output to the container log only, and removes any `seed_state.json` from `/workspace`.
  Ground truth the grader needs ships in `tests/`, which Harbor uploads only at verify time.
- **Endpoint.** Seed, solution, and verifier refuse any endpoint other than
  `http://127.0.0.1:5003` and use the dummy `test`/`test` identity. Tasks are written for
  region `us-east-1` and account `123456789012`, which the runner injects.
- **No teardown.** Every trial gets a fresh emulator, so tasks ship no cleanup step.

The image-layer copy of `seed/` is not reachable from inside the container, but this is
still shared-container execution and is not claimed tamper-proof.
