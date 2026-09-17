# Evaluation

## Current smoke check

The [minimal SDK task](smoke-test.md) checks only bucket existence. Its verifier writes `1`
for the required bucket, `0` for absence, and **no reward** for an evaluation error.
Oracle/nop runs validate the pipeline, not model capability. Emulator support reports live
in a separate runner table and never modify binary rewards.

## Primary metric: pass@1 / task success rate

For an initial pass@1 estimate, use a fixed attempt policy and configuration. With one attempt per task, task success rate is the number of successful tasks divided by the number of valid evaluated tasks. When repeating each task, report per-task counts and mean trial success, not best-of-N success. Do not choose the best of repeated attempts and label it pass@1.

Each valid trial has a binary reward: `1` only if every required final-state check passes, otherwise `0`. Harbor reads `/logs/verifier/reward.txt` and owns execution, logging, and aggregation. CloudOpsBench supplies task semantics, not a runner.

Always report task-set revision, denominator, exclusions, infrastructure errors, agent/model configuration, attempt policy, timeouts, and tool/emulator/Harbor versions. Agent timeouts count as failures under the published budget. Emulator unavailability, invalid setup, or verifier crashes are evaluation errors: report separately and rerun under a declared policy, never silently omit them to improve scores. The current blocked scaffold is not eligible for scoring.

## Verifier requirements

- Query actual resulting infrastructure state whenever possible; do not compare Terraform text to the oracle or trust agent-reported success.
- Require reference solutions to pass on fresh, isolated scopes.
- Require intentionally incorrect solutions to fail, with a negative control for each requirement.
- Accept semantically equivalent correct solutions.
- Check API fidelity against the intended semantics. An emulator returning a configured value does not automatically prove real cloud behavior.
- Use bounded retries only for documented readiness/consistency behavior, not arbitrary sleeps or indefinite polling.
- Preserve diagnostic evidence; never log credentials.

The S3 example checks existence, enabled versioning, all four public-access blocks, default SSE configuration, and the required tag through normal S3 API concepts. Configuration errors currently exit `2`; assertion failures exit `1`; successful checks exit `0`. The shell emits a conservative zero reward on errors. This is fail-closed output, **not proof that infrastructure errors are ordinary task failures**. Harbor's collected errors and verifier logs must be reviewed before aggregation.

## Verifier isolation

Agents should not receive verifier logic or reference solutions in the task image. Harbor uploads tests after the agent phase in shared mode and the oracle uploads solutions separately. This timing alone does not prevent tampering with the shared runtime. Public source code is also visible outside a trial.

Before untrusted evaluation, use and validate Harbor's separate verifier environment or an equally reviewed isolation boundary. Keep verifier credentials, endpoints, dependencies, and rewards outside agent control. The verifier must still query the exact emulator scope that the agent changed. This remains TODO; the scaffold does not claim hidden, tamper-proof grading.

## Future secondary metrics

Potential secondary metrics include security correctness, policy compliance, cost constraints, unnecessary/collateral resource changes, completion time, token usage, and infrastructure efficiency. They need explicit definitions, validated emulator support, and reproducible collection. None are implemented here. A task may require a security property as part of its binary objective without introducing a separate security score.

PASS/FAIL remains the primary initial benchmark metric. No results or leaderboard are published. See the [roadmap](roadmap.md).
