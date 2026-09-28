# Evaluation

## Canonical task grading

The runner executes the original `tests/check.py` using the [lifecycle contract](seeded-tasks.md).
Its wrapper maps explicit exit 0 to reward `1`, explicit exit 1 to reward `0`, and uncaught
Python exceptions or other exit codes to evaluation errors with **no reward**. Setup errors
also yield no scored attempt. Existing graders that catch an infrastructure error and
explicitly fail retain that behavior; the wrapper cannot infer intent without changing tests.
[Oracle/nop controls](smoke-test.md) validate the pipeline, not model capability.
Emulator-support reports are separate from scoring and never modify binary rewards.

## Primary metric: pass@1 / task success rate

For an initial pass@1 estimate, use a fixed attempt policy and configuration. With one attempt per task, task success rate is the number of successful tasks divided by the number of valid evaluated tasks. When repeating each task, report per-task counts and mean trial success, not best-of-N success. Do not choose the best of repeated attempts and label it pass@1.

Each valid trial has a binary reward: `1` only if every required final-state check passes, otherwise `0`. Harbor reads `/logs/verifier/reward.txt` and owns execution, logging, and aggregation. CloudOpsBench supplies task semantics, not a runner.

Always report task-set revision, denominator, exclusions, infrastructure errors, agent/model configuration, attempt policy, timeouts, and tool/emulator/Harbor versions. Agent timeouts count as failures under the published budget. Emulator unavailability, invalid setup, or verifier crashes are evaluation errors: report separately and rerun under a declared policy, never silently omit them to improve scores. The canonical runtime still requires end-to-end validation; packaging checks are not a release-ready leaderboard.

## Verifier requirements

- Query actual resulting infrastructure state whenever possible; do not compare Terraform text to the oracle or trust agent-reported success.
- Require reference solutions to pass on fresh, isolated scopes.
- Require intentionally incorrect solutions to fail, with a negative control for each requirement.
- Accept semantically equivalent correct solutions.
- Check API fidelity against the intended semantics. An emulator returning a configured value does not automatically prove real cloud behavior.
- Use bounded retries only for documented readiness/consistency behavior, not arbitrary sleeps or indefinite polling.
- Preserve diagnostic evidence; never log credentials.

Each task defines its own semantic checks. Preserve those checks across AWS and emulator
execution. Review Harbor's collected errors and verifier logs before aggregation; do not
silently reinterpret an infrastructure problem as agent failure.

## Verifier isolation

Agents should not receive verifier logic or reference solutions in the task image. Harbor uploads tests after the agent phase in shared mode and the oracle uploads solutions separately. This timing alone does not prevent tampering with the shared runtime. Public source code is also visible outside a trial.

Before untrusted evaluation, use and validate Harbor's separate verifier environment or an equally reviewed isolation boundary. Keep verifier credentials, endpoints, dependencies, and rewards outside agent control. The verifier must still query the exact emulator scope that the agent changed. This remains TODO; the current tasks do not claim hidden, tamper-proof grading.

## Future secondary metrics

Potential secondary metrics include security correctness, policy compliance, cost constraints, unnecessary/collateral resource changes, completion time, token usage, and infrastructure efficiency. They need explicit definitions, validated emulator support, and reproducible collection. None are implemented here. A task may require a security property as part of its binary objective without introducing a separate security score.

PASS/FAIL remains the primary initial benchmark metric. No results or leaderboard are published. See the [roadmap](roadmap.md).
