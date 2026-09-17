# Task specification

## Harbor compatibility

The new [SDK smoke task](smoke-test.md) targets the installed Harbor **0.21.0** release.
The detailed secure-bucket scaffold conventions below remain applicable to that older,
blocked Terraform example; its source-only validation is not runtime certification.

Canonical references: [Harbor task documentation](https://harborframework.com/docs/tasks), [official source documentation](https://github.com/harbor-framework/harbor/blob/96a13544537e54be84c0f316f8c3156769380684/docs/content/docs/tasks/index.mdx), and [configuration model](https://github.com/harbor-framework/harbor/blob/96a13544537e54be84c0f316f8c3156769380684/src/harbor/models/task/config.py).

This scaffold targets upstream revision `96a13544537e54be84c0f316f8c3156769380684`, whose current `schema_version` is `"1.4"`. CLI source and task documentation were inspected directly, and the example TOML passed this revision's official `TaskConfig.model_validate_toml` in a temporary validation environment. This is a source compatibility target, not a certified runtime release or completed execution test. Before release, pin and test an available Harbor version. Use `harbor tasks schema` to inspect the installed schema and `harbor run --help` for its CLI.

Do not substitute legacy Terminal-Bench `task.yaml`, `run-tests.sh`, or flat timeout fields. Harbor's current format is:

```text
<task>/
├── instruction.md
├── task.toml
├── environment/
│   └── Dockerfile
├── solution/
│   ├── solve.sh
│   └── main.tf
└── tests/
    ├── test.sh
    └── test_infra.py
```

`main.tf` and `test_infra.py` are CloudOpsBench implementation choices. Harbor requires the shell entry points for this Linux task; a solution is optional upstream but required for releasable CloudOpsBench tasks. Docker is our initial environment target, not a Harbor-wide requirement.

## Fields and conventions

| Concept | Location / meaning |
| --- | --- |
| Task ID | CloudOpsBench `metadata.id`: `aws/create-secure-s3-bucket`; path under `tasks/` |
| Harbor package identity | Canonical `[task].name`: `cloudopsbench/aws-create-secure-s3-bucket` in Harbor's `org/name` format; not a claim of registry publication |
| Provider | CloudOpsBench `metadata.provider`, initially `aws` |
| Category | CloudOpsBench `metadata.category`, example `storage` |
| Difficulty | CloudOpsBench `metadata.difficulty`, provisional `easy`, `medium`, or `hard` |
| Status | CloudOpsBench `metadata.status`, example `scaffold`; informational, **not a Harbor execution gate** |
| Instruction | `instruction.md`: user-facing objective and all scored requirements |
| Initial state | Document in instruction and implement deterministic environment bootstrap; empty scope for S3, bootstrap TODO |
| Environment | Canonical `[environment]`, plus Docker build definition; workspace chosen through Docker `WORKDIR /workspace` |
| Allowed tools | Instruction and installed environment; Terraform required, shell permitted, AWS CLI planned for inspection; not a custom Harbor config field |
| Reference solution | `solution/solve.sh` and helpers; Harbor oracle copies these to `/solution` |
| Verifier | `tests/test.sh` and helpers; shared-mode Harbor copies these to `/tests` |
| Expected final state | Instruction requirements mapped to semantic assertions in verifier |
| Constraints | Instruction; emulator-only access, Terraform workspace and bucket requirements |
| Timeout | Canonical `[agent].timeout_sec`, `[verifier].timeout_sec`, `[environment].build_timeout_sec`; provisional budgets, calibrate after integration |
| Scoring | `tests/test.sh` writes scalar `0` or `1` to `/logs/verifier/reward.txt` |

Harbor permits arbitrary `[metadata]`; the keys above are CloudOpsBench conventions, not upstream validation or routing features. Suggested future categories: provisioning, debugging, networking, iam, security, storage, databases, compute, containers, observability, recovery, migration, cost, multi-service. Difficulty should be justified and calibrated, not inferred from file length.

Harbor's reserved paths include `/tests`, `/solution`, `/logs/verifier`, and `/logs/agent`. Harbor does **not** mandate `/workspace`; CloudOpsBench chooses it in the Dockerfile. Scripts use absolute helper paths because Harbor executes them from the environment's working directory. Keep solutions and tests out of the agent image's build context.

## Quality contract

A release-ready task has:

1. A clear user-facing infrastructure objective.
2. A deterministic starting state.
3. An isolated environment.
4. A known-good reference solution tested through Harbor's oracle.
5. A verifier checking semantics/final cloud state.
6. No dependence on real cloud credentials.
7. Reproducible results, including negative controls.

The example does **not** yet meet this contract: environment, connection, and execution evidence are TODO. Structural validity must never be represented as benchmark readiness.

## S3 scoring contract

Required bucket: `cloudopsbench-data`. All checks must pass:

- Bucket exists (`HeadBucket`).
- `GetBucketVersioning` reports `Enabled`.
- All four bucket-level `GetPublicAccessBlock` flags are true.
- `GetBucketEncryption` reports a default SSE algorithm: `AES256`, `aws:kms`, or `aws:kms:dsse`.
- `GetBucketTagging` includes `Environment=production`.

The oracle uses SSE-S3 (`AES256`); equivalent valid encryption is accepted. This is configuration verification, not a complete proof of S3 authorization or encryption-at-rest implementation. Emulator API fidelity and any behavioral security probes must be validated before release. Missing resources/configuration fail; connection/configuration failures are evaluation errors, never success. See [evaluation](evaluation.md).
