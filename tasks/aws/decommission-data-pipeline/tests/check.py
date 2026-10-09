#!/usr/bin/env python3
"""ext_archit_decommission_data grader (bundle) — full-decommission completeness check.

PASS iff NOTHING carrying the per-run prefix remains, swept across BOTH regions and ALL
services in scope (DynamoDB, Kinesis, ECR, SQS). FAIL if anything is left — most often the
cross-region orphans (the agent's sweep was single-region) or the niche/less-enumerated
services (Kinesis streams, ECR repositories the agent forgot to check).

DynamoDB and Kinesis delete asynchronously, so a correct agent's deletes may still be
propagating: a table/stream in status DELETING, not-found, or any non-ACTIVE state counts as
GONE, so we don't fail a correct answer on lag.

Control: setup always creates the obvious home-region resources, so a no-op leaves them and
fails. Reads ./seed_state.json (CWD) for the prefix + the two regions. Exit 0 = PASS
("OK: ..."), non-zero = FAIL ("FAIL: ..." to stderr).
"""
import json
import subprocess
import sys


def aws(args, region=None):
    cmd = ["aws", *args, "--output", "json"]
    if region:
        cmd += ["--region", region]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            return None
        return json.loads(r.stdout) if r.stdout.strip() else None
    except Exception:
        return None


def table_gone(name, region):
    """A DynamoDB table counts as gone if absent or no longer ACTIVE (e.g. DELETING)."""
    d = aws(["dynamodb", "describe-table", "--table-name", name], region)
    if not d:
        return True  # not-found / error -> gone
    return (d.get("Table", {}) or {}).get("TableStatus", "") != "ACTIVE"


def stream_gone(name, region):
    """A Kinesis stream counts as gone if absent or no longer ACTIVE (e.g. DELETING)."""
    d = aws(["kinesis", "describe-stream-summary", "--stream-name", name], region)
    if not d:
        return True  # not-found / error -> gone
    return (d.get("StreamDescriptionSummary", {}) or {}).get("StreamStatus", "") != "ACTIVE"


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


try:
    p = json.load(open("seed_state.json"))
except Exception as e:
    fail(f"seed_state.json unreadable ({e}) — setup did not run")

prefix = p.get("prefix")
if not prefix:
    fail("prefix missing from seed_state.json — setup did not run")
regions = [p.get("primary_region", "us-east-1"), p.get("secondary_region", "us-west-2")]

remaining = []
for region in regions:
    # DynamoDB tables (async delete: DELETING / not-found / not-ACTIVE == gone)
    for name in (aws(["dynamodb", "list-tables"], region) or {}).get("TableNames", []):
        if prefix in name and not table_gone(name, region):
            remaining.append(f"dynamodb/{region}/{name}")
    # Kinesis streams (async delete: DELETING / not-found / not-ACTIVE == gone)
    for name in (aws(["kinesis", "list-streams"], region) or {}).get("StreamNames", []):
        if prefix in name and not stream_gone(name, region):
            remaining.append(f"kinesis/{region}/{name}")
    # ECR repositories
    for r in (aws(["ecr", "describe-repositories"], region) or {}).get("repositories", []):
        if prefix in r.get("repositoryName", ""):
            remaining.append(f"ecr/{region}/{r.get('repositoryName')}")
    # SQS queues
    qs = aws(["sqs", "list-queues", "--queue-name-prefix", prefix], region) or {}
    for u in qs.get("QueueUrls", []) or []:
        remaining.append(f"sqs/{region}/{u.split('/')[-1]}")

if remaining:
    away = [r for r in remaining if f"/{regions[1]}/" in r]
    niche = [r for r in remaining if r.startswith("kinesis/") or r.startswith("ecr/")]
    msg = f"INCOMPLETE decommission — {len(remaining)} left: {remaining}."
    if away:
        msg += f" Cross-region orphans (agent swept one region): {away}."
    if niche:
        msg += f" Niche/less-enumerated left: {niche}."
    fail(msg)

print(f"OK: nothing carrying prefix '{prefix}' remains in {regions[0]} or {regions[1]}")
sys.exit(0)
