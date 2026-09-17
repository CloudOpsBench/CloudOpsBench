# Contributing to CloudOpsBench

Thanks for helping build an executable infrastructure benchmark. We welcome documentation fixes, verifier reviews, emulator integration work, and realistic task proposals.

## Propose before building

Use the new-task issue template to describe provider/services, realistic user objective, deterministic initial state, desired final state, difficulty, verifier strategy, and reference-solution feasibility. Check existing issues first. For now, prioritize the minimal SDK S3 smoke task and the blocked AWS + Terraform S3 task rather than expanding scaffolds.

## Create a task

Read the [architecture](docs/architecture.md), [task specification](docs/task-specification.md), and [step-by-step tutorial](docs/creating-tasks.md). Use `tasks/<provider>/<lowercase-hyphenated-objective>/`; keep CloudOpsBench IDs unique and Harbor package names in `org/name` format.

CloudOpsBench owns tasks; Harbor is the harness. Do not add a custom runner or vendor Harbor. Keep changes focused and dependencies justified.

## Quality bar

- Clear objectives and explicit constraints, with no surprise verifier requirements.
- Deterministic initial state, isolated emulator scope, and reliable cleanup.
- Reference solution tested through Harbor's oracle, not merely plausible code.
- Semantic final-state verification, equivalent-solution acceptance, and negative controls.
- No flaky timing assumptions, uncontrolled downloads, or dependence on external mutable state.
- No real cloud accounts, credentials, host profiles, or production endpoints. Do not paste secrets into issues, PRs, fixtures, or logs.
- Document dependency versions, emulator assumptions, limitations, and reproducible commands.
- Treat verifier tampering and real-cloud fallback as safety bugs.

The secure-bucket Terraform example is explicitly blocked; the SDK bucket task is an integration smoke test, not a calibrated benchmark. Scaffold contributions may retain documented TODOs, but cannot be counted as validated tasks.

## Pull request process

1. Discuss scope in an issue, especially for new tasks or architecture changes.
2. Work on a branch; keep the PR limited to one coherent change.
3. Run `python3 scripts/validate.py` from the repository root and shell syntax checks from the tutorial.
4. When integration exists, run the oracle, negative controls, and appropriate agent trials through Harbor. Include sanitized logs/rewards and exact versions/commands.
5. Update affected documentation and complete the PR checklist. State what was not tested and why.
6. Request review; address reproducibility, safety, and verifier correctness feedback before merge.

Do not present static checks as end-to-end validation. Contributions are under the repository's [MIT license](LICENSE).

## Task submission checklist

- [ ] Proposal linked; realistic scope and unique name.
- [ ] Harbor schema and CloudOpsBench metadata conventions followed.
- [ ] Objective, initial state, allowed tools, workspace, and constraints documented.
- [ ] Emulator-only routing/identity and isolation verified; no secrets committed.
- [ ] Reference solution passes repeatedly on fresh scopes.
- [ ] Negative controls fail and equivalent valid implementations pass.
- [ ] Verifier checks final cloud state and has a reviewed integrity boundary.
- [ ] Tool/provider/emulator versions pinned; timeouts justified; cleanup tested.
- [ ] Local validation passes and execution evidence is attached where runnable.
- [ ] Documentation and TODO/status claims match actual functionality.
