---
name: Bug report
about: Report a reproducibility, task, verifier, or documentation problem
title: "[Bug] "
labels: ""
assignees: ""
---

## Problem

What went wrong? Which task/file and repository revision are affected?

## Reproduction

Commands, minimal steps, and sanitized logs. Do not include credentials, tokens, or private cloud data.

## Expected vs actual behavior

Is this an agent failure, verifier defect, environment error, or documentation mismatch?

## Environment

OS/architecture, Docker, Harbor version, emulator version (if integrated), Terraform/provider versions, and agent/model configuration where relevant.

## Scope and safety

Does this involve state leaking between trials, verifier tampering, flaky behavior, or real-cloud fallback? For suspected credential exposure, do not post the secret; revoke it first.

## Known limitations checked

The S3 example is currently an intentionally blocked scaffold. Explain whether this issue concerns an existing TODO or unexpected behavior.
