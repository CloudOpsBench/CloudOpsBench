# Roadmap

No release dates are assigned. Checked items exist in this repository; unchecked items are planned.

## Phase 0 — Infrastructure

- [x] Minimal repository and community templates; MIT license.
- [x] Architecture, preliminary task specification, and contributor documentation.
- [x] One Harbor-format S3 scaffold with reference resources and semantic checks.
- [x] Validate the minimal SDK S3 task end-to-end on Harbor 0.21.0: oracle 1, nop 0, two concurrent oracle passes; see [evidence](smoke-test.md#executed-smoke-evidence).
- [ ] Complete the separate secure-bucket Terraform task integration.

The TODO inventory below concerns full benchmark readiness, not whether the SDK smoke
path can execute. Smoke success does not close adversarial isolation or fidelity gates.

### Emulator integration TODO inventory

- [ ] Choose deployment topology and actual emulator artifact/version; document supported S3 API behavior.
- [ ] Define per-trial scope provisioning, empty initial state, readiness, reset, concurrency isolation, and teardown on every exit path.
- [ ] Define actual endpoints, region semantics, TLS, S3 addressing, and emulator-only identity provisioning; no values are assumed here.
- [ ] Configure Terraform provider and standard AWS SDK/CLI routing with no public-cloud fallback, metadata credentials, or host profiles.
- [ ] Enforce and test network isolation while permitting necessary agent/model communication.
- [ ] Install and pin tools, provider and SDK dependencies; cache providers, add lock files and image digests.
- [ ] Implement the verifier connection factory and distinguish expected absent-resource responses from transport/auth/backend errors.
- [ ] Validate encryption, versioning, tagging, and public-access-block API fidelity and any required bounded consistency waits.
- [ ] Protect verifier execution and reward artifacts; integrate a separate verifier environment with trusted access to the same scope.
- [ ] Remove deliberate guards in `environment/Dockerfile`, `solution/solve.sh`, and `tests/test_infra.py` only after the above safety work.
- [ ] Validate oracle, negative controls, equivalent solutions, and one real agent; record reproducible commands and sanitized artifacts.
- [ ] Update instructions/status from scaffold to validated only with execution evidence.

## Phase 1 — Prototype

- [ ] Get the S3 task running end-to-end against our emulator.
- [ ] Reach five high-quality AWS + Terraform tasks, only after the first integration works.
- [ ] Deterministic verifiers and passing oracle/reference solutions for each task.
- [ ] Run at least one real agent end-to-end.
- [ ] Enforce/document Terraform provenance without relying solely on generated text or untrusted local state.

## Phase 2 — CloudOpsBench v0.x

- [ ] Expand AWS coverage across realistic objectives.
- [ ] Refine provisional task categories and calibrate difficulty.
- [ ] Evaluate multiple frontier agents/models with documented configurations.
- [ ] Improve validation/CI, negative-control testing, isolation tests, and reproducibility.

## Phase 3 — CloudOpsBench v1.0

- [ ] Curated, versioned benchmark release with stable task contracts.
- [ ] Public results with error accounting and reproducible evaluation instructions.
- [ ] Paper or technical report describing methodology and emulator limitations.

## Future

Azure, GCP, OpenTofu, Pulumi, CloudFormation, CDK, Kubernetes/cloud-ops tasks, and multi-cloud scenarios. These are directions, not implemented support.
