#!/usr/bin/env python3
"""aws_task12 grader (bundle) — Lambda alias promote strands a version-pinned ESM.

PASS iff the rollout is complete AND non-stranding, all read from live AWS state:
  * promoted    — the `live` alias resolves to code different from the recorded OLD sha
  * esm_enabled — the hidden SQS event-source mapping is in an active state
  * esm_on_new  — that ESM now invokes the same code the `live` alias points at

The trap: an out-of-band SQS ESM is pinned to a NUMBERED old version (not the alias),
so promoting the alias alone leaves the consumer stranded on stale code. A correct fix
promotes AND repoints the ESM at the promoted alias/new version.

FUNC is derived from $AWS_REGION; the OLD CodeSha256 ground truth is read from SSM at
/vera/<func>/old-sha (written by setup). Exit 0 = PASS, non-zero = FAIL.
"""
import json, os, subprocess, sys

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")


def _aws(args):
    """Run an `aws` CLI command (JSON output). Returns (ok, stdout-or-stderr)."""
    try:
        r = subprocess.run(["aws", *args, "--region", REGION, "--output", "json"],
                           capture_output=True, text=True, timeout=60)
        return r.returncode == 0, (r.stdout.strip() or r.stderr.strip())
    except Exception as e:
        return False, str(e)


def _parse_json(out):
    try:
        return json.loads(out)
    except Exception:
        return None


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


if not REGION:
    fail("AWS_REGION not set")

FUNC = f"vera-order-processor-{REGION}"

ok, out = _aws(["ssm", "get-parameter", "--name", f"/vera/{FUNC}/old-sha"])
if not ok:
    fail("recorded original code sha (/vera/<func>/old-sha) not found — setup issue")
old_sha = (_parse_json(out) or {}).get("Parameter", {}).get("Value")

ok, out = _aws(["lambda", "get-function", "--function-name", f"{FUNC}:live"])
if not ok:
    fail(f"could not resolve the `live` alias of {FUNC}")
live_sha = (_parse_json(out) or {}).get("Configuration", {}).get("CodeSha256")
promoted = bool(live_sha and old_sha and live_sha != old_sha)

# Locate the hidden event-source mapping for this function (reverse-lookup).
ok, out = _aws(["lambda", "list-event-source-mappings", "--function-name", FUNC])
esms = (_parse_json(out) or {}).get("EventSourceMappings", []) if ok else []
if not esms:
    ok, out = _aws(["lambda", "list-event-source-mappings"])
    esms = [m for m in (_parse_json(out) or {}).get("EventSourceMappings", [])
            if FUNC in (m.get("FunctionArn") or "")]

problems = []
if not esms:
    problems.append("the SQS event-source mapping for the function is gone — the hidden "
                    "consumer was deleted instead of repointed")
    if not promoted:
        problems.append("the `live` alias still resolves to the old code — never promoted")
    fail("; ".join(problems))

esm = esms[0]
state = esm.get("State")
fn_arn = esm.get("FunctionArn")
esm_enabled = state in ("Enabled", "Creating", "Updating")

esm_sha = None
if fn_arn:
    ok, out = _aws(["lambda", "get-function", "--function-name", fn_arn])
    esm_sha = (_parse_json(out) or {}).get("Configuration", {}).get("CodeSha256") if ok else None
esm_on_new = bool(esm_sha and live_sha and esm_sha == live_sha)

if not promoted:
    problems.append("the `live` alias still resolves to the old code — the new handler was never promoted")
if not esm_enabled:
    problems.append(f"the event-source mapping is in state {state!r}, not Enabled — the consumer was broken")
elif not esm_on_new:
    problems.append("the event-source mapping still invokes old code — it was left pinned to the "
                    "old version; the hidden consumer is stranded on stale code (reverse-lookup not performed)")

if problems:
    fail("; ".join(problems))

print(f"OK: `live` promoted to new code and the hidden SQS ESM (state {state}) tracks it")
sys.exit(0)
