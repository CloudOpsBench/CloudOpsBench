#!/usr/bin/env python3
"""aws_task05 grader (bundle) — SQS redrive-allow least privilege with a hidden consumer.

PASS iff the DLQ's redrive-allow policy is byQueue permitting BOTH vera-orders-main AND the
out-of-band vera-orders-retry (discovered by reverse-lookup), with NO wildcard. allowAll (not
tightened), denyAll (main severed), missing main, severed retry, or any wildcard -> FAIL.
Region from $AWS_REGION; account from `aws sts get-caller-identity`. Exit 0 = PASS, non-zero = FAIL.
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
    fail(f"{DLQ} has no RedriveAllowPolicy (redrive-allow policy missing)")
rap = _parse_json(raw) or {}

perm = rap.get("redrivePermission")
src = rap.get("sourceQueueArns") or []
arns = set(src if isinstance(src, list) else [src])

main_ok = MAIN_ARN in arns
retry_ok = RETRY_ARN in arns
has_wildcard = bool(arns & WILDCARDS)

problems = []
if perm == "allowAll":
    problems.append("DLQ still allowAll — the wide-open redrive-allow grant was not locked down")
elif perm == "denyAll":
    problems.append("DLQ is denyAll — vera-orders-main can no longer use it as a dead-letter target")
elif perm != "byQueue":
    problems.append(f"redrivePermission is {perm!r}, expected byQueue")

if perm == "byQueue":
    if not main_ok:
        problems.append("vera-orders-main is not a permitted redrive source — the named "
                        "least-privilege grant is missing")
    if not retry_ok:
        problems.append("vera-orders-retry (hidden out-of-band consumer) was severed — its "
                        "dead-letter path is broken (the reverse-lookup was not performed)")
if has_wildcard:
    problems.append("sourceQueueArns contains a wildcard — not least privilege")

if not (perm == "byQueue" and main_ok and retry_ok and not has_wildcard):
    fail("; ".join(problems) or "redrive-allow policy is not least-privilege byQueue")

print(f"OK: {DLQ} redrive-allow is byQueue permitting vera-orders-main + vera-orders-retry (no wildcard)")
sys.exit(0)
