## Summary

Describe the change and link related issues/proposals.

## Status

What is implemented? What is planned/blocked? Does this change add a validated task or only a scaffold?

## Validation

List exact commands, versions (Harbor, emulator, tools, agent/model), outcomes, and sanitized evidence. Explain anything not tested.

For tasks: include oracle results, repeated fresh-scope runs, negative controls, equivalent-solution checks, and isolation/cleanup evidence.

## Checklist

- [ ] Scope is focused; no custom harness or unnecessary dependencies.
- [ ] Documentation and relative links match actual files and behavior.
- [ ] `python3 scripts/validate.py` and relevant syntax checks pass.
- [ ] Harbor schema/CLI compatibility checked where relevant.
- [ ] No secrets, real cloud credentials, host profiles, or unsafe cloud fallback.
- [ ] Task requirements are public and verifiers check final state.
- [ ] Reference solution and negative controls tested, or blockers explicitly stated.
- [ ] Emulator integration, verifier integrity, reproducibility, and cleanup reviewed.
