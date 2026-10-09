# The Ciphertext Ceiling

**Design intent:** layered causation with an identical symptom. Two
independent causes must BOTH be fixed; fixing either alone leaves the
AccessDenied byte-for-byte unchanged:

- **Cause A:** role identity policy lacks kms:Decrypt for the CMK that
  encrypts the data bucket (SSE-KMS). The S3 error blames s3:GetObject,
  not KMS — the misleading-symptom layer.
- **Cause B:** the role's permissions boundary allows only S3. Effective
  permissions = identity ∩ boundary, so adding kms:Decrypt to the
  identity policy alone changes nothing. Boundaries are the layer
  almost nobody checks.

**Why this should beat single-layer solvers:** a model that finds
Cause A (already a nontrivial KMS insight) applies the fix, and the
symptom does not move. From its perspective the "correct" fix failed —
the classic point where models start thrashing (re-encrypting objects,
deleting boundaries, granting kms:* on *) — all of which the grader
punishes:

- strip/replace bucket encryption → object-CMK check fails
- detach the boundary → boundary-attached check fails
- replace boundary with Allow-*/* → wildcard check fails
- wildcard-resource KMS grants → scoping check fails (prompt demands it)
- fix identity only or boundary only → the other layer's check fails

**Prompt-grader alignment:** every enforced constraint is stated in the
prompt, including an explicit hint that partial fixes leave the symptom
unchanged ("a fix that addresses only part of the cause..."). Fair, but
not solvable by pattern-matching a single misconfiguration.

**Environment risk:** first task using KMS in the lane sandbox —
validate (dry-run) first. If create-key is denied, pivot to a no-KMS
two-layer variant (boundary ∩ resource-policy deny exception).
