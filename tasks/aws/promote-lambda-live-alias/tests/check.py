#!/usr/bin/env python3
"""Check that the `live` alias runs new code and the SQS event-source mapping follows it.

Passes when the alias resolves to a code hash different from /vera/<func>/old-sha in
SSM, and the function's event-source mapping is active and resolves to the same code
hash as the alias.
"""
import json, os, subprocess, sys

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")


def _aws(args):
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
    fail(f"/vera/{FUNC}/old-sha not found")
old_sha = (_parse_json(out) or {}).get("Parameter", {}).get("Value")

ok, out = _aws(["lambda", "get-function", "--function-name", f"{FUNC}:live"])
if not ok:
    fail(f"could not resolve the `live` alias of {FUNC}")
live_sha = (_parse_json(out) or {}).get("Configuration", {}).get("CodeSha256")
promoted = bool(live_sha and old_sha and live_sha != old_sha)

ok, out = _aws(["lambda", "list-event-source-mappings", "--function-name", FUNC])
esms = (_parse_json(out) or {}).get("EventSourceMappings", []) if ok else []
if not esms:
    ok, out = _aws(["lambda", "list-event-source-mappings"])
    esms = [m for m in (_parse_json(out) or {}).get("EventSourceMappings", [])
            if FUNC in (m.get("FunctionArn") or "")]

problems = []
if not esms:
    problems.append("no event-source mapping found for the function")
    if not promoted:
        problems.append("the `live` alias still resolves to the old code")
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
    problems.append("the `live` alias still resolves to the old code")
if not esm_enabled:
    problems.append(f"the event-source mapping is in state {state!r}, not Enabled")
elif not esm_on_new:
    problems.append("the event-source mapping still invokes the old code")

if problems:
    fail("; ".join(problems))

print(f"OK: `live` runs the new code and the event-source mapping (state {state}) follows it")
sys.exit(0)
