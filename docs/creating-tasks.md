# Creating a task

Start by reading the [specification](task-specification.md) and opening a task proposal. Use `tasks/<provider>/<lowercase-hyphenated-objective>/`; IDs must be unique. The first objective is `aws/create-secure-s3-bucket`.

## 1. Define the objective and initial state

Write `instruction.md` as a request to the agent, not a recipe copied from the oracle. State the workspace, allowed tools, initial state, desired resource properties, and constraints. For the example: an empty isolated emulator scope, Terraform in `/workspace`, bucket `cloudopsbench-data`, versioning, all four public-access blocks, SSE, and the production tag.

Do not hide additional scored requirements in tests. Task author notes and integration TODOs must be clearly distinguishable from the infrastructure request.

## 2. Create the Harbor structure

For a new task (do not overwrite the existing example):

```bash
mkdir -p tasks/aws/<new-task-name>/{environment,solution,tests}
```

Create `instruction.md`, `task.toml`, `environment/Dockerfile`, `solution/solve.sh`, and `tests/test.sh`. You can also consult the installed Harbor task generator via `harbor init --help`. Follow the current [schema](task-specification.md#harbor-compatibility), not an older Terminal-Bench template.

Populate canonical configuration sections and CloudOpsBench metadata separately. Set finite timeouts. `metadata.status = "scaffold"` documents incompleteness but does not prevent Harbor execution.

## 3. Build the environment

The S3 Dockerfile chooses `/workspace` and deliberately fails construction until integration is defined. TODO: install pinned Terraform, AWS provider/cache, AWS CLI, Python and verifier SDK dependencies; choose and pin the base image digest. Do not copy `solution/` or `tests/` into the agent image.

TODO: integrate emulator provisioning, readiness, isolated initial state, emulator-only connection/identity settings, network restrictions, and teardown. Do not invent endpoints or credentials or reuse host AWS configuration. Verify concurrent trials cannot share bucket state. Document the actual integration once known.

## 4. Write the reference solution

`solution/main.tf` illustrates standard Terraform AWS S3 resources. `solution/solve.sh` describes the intended copy → init → validate → apply flow but currently exits before it can run. There is no provider connection configuration yet. TODO: supply trusted emulator-only provider configuration, pin Terraform/provider versions and generate a lock file; remove the guard only after safety and connectivity validation.

An oracle must satisfy the same public objective as an agent; it must not write rewards, call verifier helpers, or bypass emulator controls.

## 5. Write semantic verification

`tests/test_infra.py` contains ordinary AWS S3 read API checks. Its connection factory deliberately raises an integration error before any SDK initialization or network access. TODO: bind a standard SDK client to the trusted trial scope with explicit emulator routing and identity, and classify missing-resource/configuration responses separately from infrastructure failures.

`tests/test.sh` writes `1` only on successful checks and `0` otherwise; exit code `2` signals an evaluation/integration error in this scaffold. The shell preserves that error status. Harbor consumes the reward file, so review errors/logs rather than counting every zero as an agent failure. Hidden or separate verification must not trust agent-modified binaries or connection files; see [architecture](architecture.md).

## 6. Validate, oracle first

Available now, from repository root:

```bash
python3 scripts/validate.py
bash -n tasks/aws/create-secure-s3-bucket/solution/solve.sh
bash -n tasks/aws/create-secure-s3-bucket/tests/test.sh
harbor tasks schema
```

Static checks confirm file layout, TOML syntax, Python syntax, and relative Markdown file links. They are not a substitute for upstream schema validation or execution. No cloud access is needed.

After emulator integration (these commands are **blocked today**):

```bash
harbor run --path tasks/aws/create-secure-s3-bucket --agent oracle --env docker
```

Inspect Harbor's job output, verifier logs, and reward. Repeat on fresh scopes and concurrently. Require reward `1` for the oracle. Use controlled incorrect variants on fresh scopes: no bucket, versioning suspended, each public-access flag false in turn, wrong/missing tag, and missing/invalid encryption where the emulator permits that state. Modern S3 may supply default encryption; test observed state rather than assuming omission of a Terraform block means no encryption.

Validate equivalent correct implementations too. Then run one supported real agent using `--agent <agent> --model <provider/model>`. Record Harbor, emulator, image, Terraform, provider, agent/model versions and commands. Do not claim an end-to-end pass from mocked API responses.

## Submission checklist

- [ ] Objective is realistic, unambiguous, and all scored constraints are public.
- [ ] Metadata, documentation, workspace, and scripts agree.
- [ ] No real cloud credentials, host profiles, or public cloud fallback.
- [ ] Deterministic seed, per-trial isolation, readiness, and teardown implemented.
- [ ] Dependencies pinned and documented; no runtime dependency downloads needed for verification.
- [ ] Oracle passes repeatedly through Harbor.
- [ ] Each negative control fails; equivalent correct solutions pass.
- [ ] Verifier integrity and emulator API fidelity reviewed.
- [ ] Static checks and installed Harbor schema validation pass.
- [ ] PR includes execution evidence, known limitations, and documentation updates.

Scaffold-only PRs are welcome when explicitly labeled; they do not add release-ready benchmark tasks. See [contributing](../CONTRIBUTING.md).
