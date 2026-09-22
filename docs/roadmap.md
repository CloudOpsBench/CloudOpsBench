# Roadmap

No release dates are assigned. Integration tests are not a production benchmark release.

## Implemented

- [x] Public Harbor-format tasks and contributor documentation.
- [x] SDK S3 task: oracle 1, nop 0, concurrent oracle passes on Harbor 0.21.0.
- [x] Secure S3 Terraform task: pinned tools, checked-in provider lock, offline mirror,
  emulator-only provider configuration, and semantic SDK verifier.
- [x] Runner-managed fresh emulator, readiness, network namespace, and ordinary cleanup.
- [x] Explicit loopback routing, dummy identity, and disabled metadata discovery.
- [x] Local unit tests distinguish missing required state from SDK/transport errors.

## Integration and release gates

- [ ] Comprehensive S3 API fidelity and equivalent-solution validation.
- [ ] Adversarial network, cross-trial, cancellation, and credential-isolation review.
- [ ] Separate trusted verifier and reward storage outside agent control.
- [ ] Fully locked transitive dependencies and long-term image retention/replay.
- [ ] Model evaluation coverage for every task with published budgets and error accounting.
- [ ] Enforce/document Terraform provenance without trusting generated text or local state.
- [ ] Stable aggregate publication and reviewed private artifact handling.

## Expansion

- [ ] Five high-quality AWS/Terraform tasks after the first task integrations are validated.
- [ ] Broader provisioning, debugging, IAM, networking, security, and multi-service coverage.
- [ ] Calibrated task difficulty, stronger CI, negative controls, and reproducible releases.
- [ ] Versioned benchmark, public results, and methodology/limitations report.

Azure, GCP, OpenTofu, Pulumi, CloudFormation, CDK, Kubernetes/cloud-ops and multi-cloud
scenarios remain future directions, not implemented support.
