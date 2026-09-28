# Architecture

CloudOpsBench owns canonical tasks. Harbor executes trials. The private runner supplies
backend configuration and runtime scaffolding without rewriting task tests.

```text
Canonical lifecycle task → runner-rendered Harbor package
                              ├── setup service → private per-trial seed state
                              ├── agent container → cloud operations
                              ├── dedicated emulator
                              └── Harbor egress-control sidecar
                                         ↓
                              unchanged grader → binary reward
```

## Ownership

| Component | Responsibility |
|---|---|
| Task | Instructions, setup, assets, grader, reference solution, optional teardown |
| Runner | Tool runtime, lifecycle ordering, endpoints, credentials, isolation, seed state, reward wiring |
| Emulator | AWS API behavior and per-trial cloud state |
| Harbor | Trial execution and artifacts |

The runner currently implements emulator execution only. Backend-neutral task logic also
permits an AWS harness to run the same scripts with real scoped credentials and cleanup;
real-AWS orchestration is not implemented here.

## Semantic consistency

Preserve setup and grading logic across backends. Equivalent correct solutions should pass;
cloud state and behavior, not reference-solution text or agent claims, determine success.
Unsupported emulator behavior is not a reason to weaken task assertions.

## Isolation and reproducibility

The setup service gates agent startup. Setup and grading share private dynamic state; the
agent runs non-root in a separate workspace. Tests are uploaded at verification time and
solutions are provided only to the oracle. These controls are not a certification of
shared-container grading against adversarial agents.

Before publishing results, validate per-trial isolation, egress, credential handling,
cleanup, grader integrity, and reward protection. Record the task commit, runtime and
emulator versions, Harbor version, timeouts, and attempt policy.

Emulator-support reports are independent of task rewards. They do not rewrite scores or
prove the cause of a failure. See [evaluation](evaluation.md), the
[task specification](task-specification.md), and [roadmap](roadmap.md).
