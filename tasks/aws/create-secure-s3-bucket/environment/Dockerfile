# Ordinary OS base, NOT an emulator image. TODO: pin its digest and tool versions.
FROM ubuntu:24.04

WORKDIR /workspace

# Deliberate build gate: this task must not appear runnable without integration.
RUN echo 'TODO: integrate isolated emulator, emulator-only identity/routing, pinned Terraform/AWS CLI/Python/SDK, readiness and cleanup before enabling this image.' >&2; exit 1

# TODO: install pinned tools and cache the AWS provider; no runtime downloads.
# TODO: define emulator deployment, endpoints, region, TLS and S3 addressing
# from the actual emulator contract. Do not inherit host cloud credentials.
# TODO: seed an empty per-trial scope and enforce denial of real cloud access.
# Do not COPY solution/ or tests/ into the agent environment.
