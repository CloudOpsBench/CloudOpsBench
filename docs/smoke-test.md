# Validating a canonical task

Use a published task that follows the [lifecycle contract](seeded-tasks.md). The ten
curated Harbor exports establish the format; do not assume they are already present in
a public task commit. Select the actual path from the pinned checkout.

## Operator procedure

In the configured private runner environment:

```bash
export TASKS_REF=REPLACE_WITH_PUBLISHED_COMMIT
export TASK_ID=aws/REPLACE_WITH_CURATED_TASK_ID
uv run cobr list-tasks --tasks-ref "$TASKS_REF"
uv run cobr render --tasks-ref "$TASKS_REF" --task "$TASK_ID" --harness oracle --seed 1
uv run cobr run --tasks-ref "$TASKS_REF" --task "$TASK_ID" --harness oracle --seed 1 -k 1 -n 1 --no-upload
uv run cobr run --tasks-ref "$TASKS_REF" --task "$TASK_ID" --harness nop --seed 1 -k 1 -n 1 --no-upload
```

Expected controls: oracle reward **1**, nop reward **0**, neither with evaluation errors.
These are acceptance criteria, not recorded results. A CLI exit code alone is insufficient;
inspect trial rewards and logs. Use a fresh emulator and state volume for every attempt.

## Required checks

- Setup completes before agent access; setup failures yield no scored attempt.
- Original setup, grader, solution, and assets remain unchanged after rendering.
- The grader receives that trial's actual seed state; the agent cannot read or modify it.
- Setup, agent, and verifier all address the same isolated emulator scope.
- Grader execution errors emit no reward; stale reward files cannot survive.
- Reference solutions pass repeatedly; nop and deliberately incomplete fixes fail.
- Cleanup removes per-trial state after success, failure, and cancellation.
- Egress, credentials, provider allowlisting, and cross-trial isolation are reviewed.

The private runtime supplies dummy credentials and `AWS_ENDPOINT_URL`; never inject real
AWS credentials into emulator containers. An independent AWS harness may run the same task
scripts with scoped credentials and teardown, but this runner does not implement that backend.

## Current evidence

The ten exports have been rendered with byte-identical core scripts. Generated Compose
configuration and Harbor 0.21 metadata validate; runner unit tests cover the adapter and
verdict handling. Full Docker/Harbor lifecycle execution is still pending. These checks do
not establish model performance, emulator fidelity, or adversarial grading security.
