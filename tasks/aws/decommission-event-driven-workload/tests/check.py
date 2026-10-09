#!/usr/bin/env python3
"""ext_archit_decommission_events grader (bundle) — full-decommission completeness check.

State-only. PASS iff NOTHING carrying the prefix remains, swept across BOTH regions and
ALL in-scope services (EventBridge rules, SQS, SNS). FAIL if anything is left — most often
the cross-region orphans (a single-region sweep misses them) or the niche EventBridge rule
(agents routinely forget `aws events list-rules` when sweeping a stack). Setup always
creates the obvious home-region resources, so a no-op leaves them and fails. Reads the
prefix + the two regions from ./seed_state.json. Exit 0 = PASS, non-zero = FAIL.
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


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


try:
    p = json.load(open("seed_state.json"))
except Exception as e:
    fail(f"seed_state.json unreadable ({e}) — setup did not run")

prefix = p.get("prefix")
if not prefix:
    fail("ground-truth prefix missing from seed_state.json")
regions = [p.get("primary_region", "us-east-1"), p.get("secondary_region", "us-west-2")]

remaining = []
for region in regions:
    # EventBridge rules (the niche service agents forget)
    for r in (aws(["events", "list-rules", "--name-prefix", prefix], region) or {}).get("Rules", []):
        name = r.get("Name", "")
        if prefix in name:
            remaining.append(f"events/{region}/{name}")
    # SQS queues
    qs = aws(["sqs", "list-queues", "--queue-name-prefix", prefix], region) or {}
    for u in qs.get("QueueUrls", []) or []:
        remaining.append(f"sqs/{region}/{u.split('/')[-1]}")
    # SNS topics
    for t in (aws(["sns", "list-topics"], region) or {}).get("Topics", []):
        arn = t.get("TopicArn", "")
        if prefix in arn:
            remaining.append(f"sns/{region}/{arn.split(':')[-1]}")

if remaining:
    away = [r for r in remaining if f"/{regions[1]}/" in r]
    niche = [r for r in remaining if r.startswith("events/")]
    fail(f"INCOMPLETE decommission — {len(remaining)} left: {remaining}. "
         + (f"Cross-region orphans (agent swept one region): {away}. " if away else "")
         + (f"Niche service left (EventBridge rules): {niche}." if niche else ""))

print(f"OK: full decommission — nothing with prefix '{prefix}' remains in {regions[0]} or {regions[1]}")
sys.exit(0)
