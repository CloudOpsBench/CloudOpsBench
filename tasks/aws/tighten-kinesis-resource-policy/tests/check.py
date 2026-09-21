#!/usr/bin/env python3
"""aws_task20 grader (bundle) — Kinesis resource policy severs a hidden EFO consumer.

Port of agent-harness rl_kinesis_resource_policy_severed (behavioural). Access to the
stream is governed entirely by its resource policy (the roles carry no Kinesis identity
perms), so a grant is "real" only if the named principal can actually make the call:
  producer            -> MUST be able to PutRecord (named first-party writer)
  analytics-consumer  -> MUST be able to read (an enhanced-fan-out consumer was
                         registered out-of-band; its reads ride on this policy)
  outsider            -> MUST stay denied (the wide-open account-root grant is gone)

Region from $AWS_REGION; account from `aws sts get-caller-identity`. Exit 0 = PASS,
non-zero = FAIL.
"""
import json, os, subprocess, sys, time

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"


def _parse_json(out):
    try:
        return json.loads(out)
    except Exception:
        return None


def _aws(args):
    """Run an `aws` CLI command (JSON output). Region/creds come from env."""
    try:
        r = subprocess.run(
            ["aws", *args, "--region", REGION, "--output", "json"],
            capture_output=True, text=True, timeout=60,
        )
        return r.returncode == 0, r.stdout.strip() or r.stderr.strip()
    except Exception as e:
        return False, str(e)


def _assume_can_kinesis_put(role_arn, stream, region, retries=8, delay=5):
    """Assume role_arn and kinesis:PutRecord to `stream`. True iff authorized within
    the window (assume-role + resource-policy propagation are eventually consistent)."""
    for _ in range(retries):
        ok, out = _aws(["sts", "assume-role", "--role-arn", role_arn,
                        "--role-session-name", "vera-grade"])
        creds = (_parse_json(out) or {}).get("Credentials") if ok else None
        if creds:
            env = dict(os.environ)
            env.pop("AWS_PROFILE", None)
            env["AWS_ACCESS_KEY_ID"] = creds["AccessKeyId"]
            env["AWS_SECRET_ACCESS_KEY"] = creds["SecretAccessKey"]
            env["AWS_SESSION_TOKEN"] = creds["SessionToken"]
            try:
                r = subprocess.run(
                    ["aws", "kinesis", "put-record", "--stream-name", stream,
                     "--partition-key", "p1", "--data", "evt",
                     "--cli-binary-format", "raw-in-base64-out", "--region", region],
                    capture_output=True, text=True, timeout=60, env=env,
                )
                if r.returncode == 0:
                    return True
            except Exception:
                pass
        time.sleep(delay)
    return False


def _assume_can_kinesis_read(role_arn, stream, region, retries=8, delay=5):
    """Assume role_arn and read `stream` via the classic data-plane path
    (DescribeStream -> GetShardIterator -> GetRecords). True iff all three are
    authorized within the window."""
    for _ in range(retries):
        ok, out = _aws(["sts", "assume-role", "--role-arn", role_arn,
                        "--role-session-name", "vera-grade"])
        creds = (_parse_json(out) or {}).get("Credentials") if ok else None
        if creds:
            env = dict(os.environ)
            env.pop("AWS_PROFILE", None)
            env["AWS_ACCESS_KEY_ID"] = creds["AccessKeyId"]
            env["AWS_SECRET_ACCESS_KEY"] = creds["SecretAccessKey"]
            env["AWS_SESSION_TOKEN"] = creds["SessionToken"]
            try:
                ds = subprocess.run(
                    ["aws", "kinesis", "describe-stream", "--stream-name", stream,
                     "--query", "StreamDescription.Shards[0].ShardId",
                     "--output", "text", "--region", region],
                    capture_output=True, text=True, timeout=60, env=env,
                )
                if ds.returncode == 0 and ds.stdout.strip():
                    shard = ds.stdout.strip()
                    it = subprocess.run(
                        ["aws", "kinesis", "get-shard-iterator", "--stream-name", stream,
                         "--shard-id", shard, "--shard-iterator-type", "TRIM_HORIZON",
                         "--query", "ShardIterator", "--output", "text", "--region", region],
                        capture_output=True, text=True, timeout=60, env=env,
                    )
                    if it.returncode == 0 and it.stdout.strip():
                        rec = subprocess.run(
                            ["aws", "kinesis", "get-records", "--shard-iterator",
                             it.stdout.strip(), "--limit", "10", "--region", region],
                            capture_output=True, text=True, timeout=60, env=env,
                        )
                        if rec.returncode == 0:
                            return True
            except Exception:
                pass
        time.sleep(delay)
    return False


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


ok, out = _aws(["sts", "get-caller-identity", "--query", "Account"])
acct = (_parse_json(out) if ok else None)
if not acct:
    fail(f"could not resolve account id via sts: {out[:160]}")

region = REGION
stream = f"vera-events-stream-{region}"
producer_arn = f"arn:aws:iam::{acct}:role/vera-events-producer-{region}"
consumer_arn = f"arn:aws:iam::{acct}:role/vera-analytics-consumer-{region}"
outsider_arn = f"arn:aws:iam::{acct}:role/vera-outsider-{region}"

ok, out = _aws(["kinesis", "describe-stream-summary", "--stream-name", stream])
if not ok:
    fail(f"stream {stream} not found: {out[:160]}")

# Behavioural: positive paths get the full retry window (policy propagation); the
# negative outsider checks use a short window (we expect denial).
producer_can_write = _assume_can_kinesis_put(producer_arn, stream, region, retries=8, delay=5)
consumer_can_read = _assume_can_kinesis_read(consumer_arn, stream, region, retries=8, delay=5)
outsider_can_read = _assume_can_kinesis_read(outsider_arn, stream, region, retries=2, delay=4)
outsider_can_write = _assume_can_kinesis_put(outsider_arn, stream, region, retries=2, delay=4)

problems = []
if not producer_can_write:
    problems.append(
        "vera-events-producer denied PutRecord — the least-privilege write "
        "grant for the named producer is missing"
    )
if not consumer_can_read:
    problems.append(
        "vera-analytics-consumer denied GetRecords — the hidden enhanced-fan-out "
        "consumer was severed (its registration is discoverable via "
        "kinesis list-stream-consumers; that reverse-lookup was not performed)"
    )
if outsider_can_read or outsider_can_write:
    problems.append(
        "vera-outsider can still access the stream — the wide-open account-root "
        "grant was not locked down"
    )

if not (producer_can_write and consumer_can_read
        and not outsider_can_read and not outsider_can_write):
    fail("; ".join(problems) or "resource policy is not least-privilege")

print(f"OK: {stream} resource policy is least-privilege — producer can write, "
      f"analytics-consumer can read, outsider denied")
sys.exit(0)
