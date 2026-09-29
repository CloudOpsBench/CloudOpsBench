#!/usr/bin/env python3
"""Check that the DLQ's redrive-allow policy is byQueue for the main and retry queues.

Fails on allowAll, denyAll, a missing main or retry queue ARN, or a wildcard source.
"""
import json, os, subprocess, sys

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"


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


ok, out = _aws(["sts", "get-caller-identity", "--query", "Account"])
acct = (_parse_json(out) if ok else None)
if not acct:
    fail(f"could not resolve account id via sts: {out[:160]}")

sfx = REGION
DLQ = f"vera-orders-dlq-{sfx}"
MAIN_ARN = f"arn:aws:sqs:{sfx}:{acct}:vera-orders-main-{sfx}"
RETRY_ARN = f"arn:aws:sqs:{sfx}:{acct}:vera-orders-retry-{sfx}"
WILDCARDS = {"*", f"arn:aws:sqs:{sfx}:{acct}:*"}

ok, out = _aws(["sqs", "get-queue-url", "--queue-name", DLQ])
if not ok:
    fail(f"{DLQ} not found: {out[:160]}")
dlq_url = (_parse_json(out) or {}).get("QueueUrl", "")

ok, out = _aws(["sqs", "get-queue-attributes", "--queue-url", dlq_url,
                "--attribute-names", "RedriveAllowPolicy"])
raw = (_parse_json(out) or {}).get("Attributes", {}).get("RedriveAllowPolicy") if ok else None
if not raw:
    fail(f"{DLQ} has no RedriveAllowPolicy")
rap = _parse_json(raw) or {}

perm = rap.get("redrivePermission")
src = rap.get("sourceQueueArns") or []
arns = set(src if isinstance(src, list) else [src])

main_ok = MAIN_ARN in arns
retry_ok = RETRY_ARN in arns
has_wildcard = bool(arns & WILDCARDS)

problems = []
if perm == "allowAll":
    problems.append("DLQ redrivePermission is still allowAll")
elif perm == "denyAll":
    problems.append("DLQ redrivePermission is denyAll, so vera-orders-main cannot use it")
elif perm != "byQueue":
    problems.append(f"redrivePermission is {perm!r}, expected byQueue")

if perm == "byQueue":
    if not main_ok:
        problems.append("vera-orders-main is not a permitted redrive source")
    if not retry_ok:
        problems.append("vera-orders-retry is not a permitted redrive source")
if has_wildcard:
    problems.append("sourceQueueArns contains a wildcard")

if not (perm == "byQueue" and main_ok and retry_ok and not has_wildcard):
    fail("; ".join(problems) or "redrive-allow policy is not least-privilege byQueue")

print(f"OK: {DLQ} redrive-allow is byQueue permitting vera-orders-main + vera-orders-retry (no wildcard)")
sys.exit(0)
