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

The ten curated Harbor exports establish this format. They have not been imported into
this repository by the runtime integration change. Remaining older task directories are
not examples of the supported authoring contract or a validated current task release.

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
and [roadmap](docs/roadmap.md). Public content is under the [MIT license](LICENSE).
