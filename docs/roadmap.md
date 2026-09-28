# Roadmap

The curated Harbor-style lifecycle contract is the sole documented task format.
No release dates or leaderboard results are implied by integration progress.

## Implemented

- Canonical source contract preserving setup, grader, assets, and solution scripts.
- Runner-generated tool/runtime packaging, private dynamic seed state, and reward wiring.
- Static validation and contributor documentation for lifecycle exports.
- Rendering and Compose/Harbor metadata checks for the ten curated Harbor exports.
- Unit tests for runtime adaptation, state handling, and verifier verdicts.

## Integration and release gates

- Publish the curated task packages at a pinned repository revision.
- Validate Docker/Harbor execution of the lifecycle runtime end-to-end.
- Run oracle, nop, incomplete-fix, and equivalent-solution controls per task.
- Review network, credential, cross-trial, cancellation, and cleanup isolation.
- Validate grader integrity and reward storage against adversarial agents.
- Lock dependencies and define long-term image retention/replay policy.
- Calibrate model budgets, task difficulty, and error accounting.
- Stabilize aggregate publication and review private artifact handling.

Real-AWS orchestration and additional cloud providers remain separate future work.
Do not fork task tests to accommodate execution backend differences.
