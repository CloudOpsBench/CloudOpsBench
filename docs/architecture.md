# Architecture

CloudOpsBench owns task content; Harbor owns execution. The private CloudOpsBenchRunner
packages tasks with a private emulator. It is an orchestration wrapper, not a fork of Harbor.

```text
Public task → private runner rendering → Harbor trial
                                         ├── agent container
                                         ├── emulator container
                                         └── egress-control sidecar
                                               ↓
                                     verifier → binary reward
```

## Current integration

The [SDK S3 smoke task](smoke-test.md) exercises the smallest useful path: an agent creates
a bucket, then a verifier queries the same emulator. The runner gives each trial a fresh
emulator process and injects its dummy identity/endpoint. Harbor controls the Compose
lifecycle. The agent and emulator share Harbor's controlled network namespace, communicating
through loopback with no emulator port published to the host.

The older secure-bucket Terraform scaffold remains blocked. Its provider integration,
offline provider mirror, and verifier connection are still TODO. It must not be mistaken
for the runnable-path SDK smoke task.

## Verify semantics, not reference text

Equivalent correct implementations should pass. Cloud state is authoritative, not Terraform
text, a saved plan, or agent-reported success. The smoke verifier checks bucket existence;
the secure-bucket scaffold additionally specifies encryption, versioning, public access, and
tags. Neither implies real AWS fidelity without independent emulator validation.

## Isolation and reproducibility

Required before publishing untrusted model results:

- Independent emulator state per trial and verified cleanup after failure/cancellation.
- Recorded task commit, emulator digest, Harbor/tool versions, seeds, and attempt policy.
- No real cloud credentials, host profiles, metadata credentials, or real-cloud API egress.
- Tested model-provider allowlisting and cross-trial isolation.
- Trusted verifier runtime and reward artifacts outside agent control.

The smoke image runs agents as a non-root user and uses root-owned tools. Harbor uploads
tests only for verification and solutions only for the oracle. This is useful separation,
but a shared container is **not a fully trusted grading boundary**: malicious processes or
runtime modifications require additional defenses. A separate verifier integration and
adversarial testing remain prerequisites for untrusted evaluation.

Emulator gap reports are independent from task rewards. They can help diagnose limitations,
but an unsupported operation alone does not prove the emulator caused a task failure.

See [task specification](task-specification.md), [evaluation](evaluation.md), and
[roadmap](roadmap.md). Future cloud providers and broader IaC coverage remain planned work.
