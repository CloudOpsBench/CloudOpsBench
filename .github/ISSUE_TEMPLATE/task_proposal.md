---
name: New task proposal
about: Propose a realistic infrastructure objective
title: "[Task] "
labels: ""
assignees: ""
---

## Proposed ID

`<provider>/<lowercase-hyphenated-objective>`

## Provider and services

Initial focus is AWS + Terraform. List required services, IaC tools, and API behavior the emulator must support; distinguish known support from TODOs.

## Task description

Write a concise user-facing objective.

## Initial state

How will state be seeded deterministically and isolated per trial?

## Desired final state and constraints

List observable success criteria, allowed tools, and prohibited collateral changes.

## Difficulty and category

Proposed difficulty and why; suggested category.

## Why is this realistic?

What infrastructure engineering capability does this evaluate beyond generating code?

## Proposed verifier

Which standard APIs or behaviors establish success? What are the negative controls? How are equivalent solutions accepted and grading protected from agent tampering?

## Reference solution feasibility

Outline a known approach and required tool/provider versions. Can it run entirely against the emulator without real cloud credentials?

## Reproducibility and open questions

Readiness, timeouts, consistency, teardown, concurrency, and unresolved emulator integration requirements.
