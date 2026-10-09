#!/usr/bin/env python3
"""Check that nothing carrying the stack prefix remains in either region.

Reads the prefix and the two regions from ./seed_state.json and passes when no Athena
work-group, Secrets Manager secret, SSM parameter or SQS queue matching the prefix is
left in either region.
"""
import json, subprocess, sys


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
run_id = p.get("run_id", "")

remaining = []
for region in regions:
    # Athena work-groups
    for wg in (aws(["athena", "list-work-groups"], region) or {}).get("WorkGroups", []):
        if prefix in wg.get("Name", ""):
            remaining.append(f"athena/{region}/{wg.get('Name')}")
    # Secrets Manager (the default list omits secrets scheduled for deletion)
    for s in (aws(["secretsmanager", "list-secrets"], region) or {}).get("SecretList", []):
        if prefix in s.get("Name", ""):
            remaining.append(f"secret/{region}/{s.get('Name')}")
    # SSM parameters, matched by prefix or by a /<run_id>/ path segment
    for par in (aws(["ssm", "describe-parameters"], region) or {}).get("Parameters", []):
        if prefix in par.get("Name", "") or (run_id and f"/{run_id}/" in par.get("Name", "")):
            remaining.append(f"ssm/{region}/{par.get('Name')}")
    # SQS queues
    qs = aws(["sqs", "list-queues", "--queue-name-prefix", prefix], region) or {}
    for u in qs.get("QueueUrls", []) or []:
        remaining.append(f"sqs/{region}/{u.split('/')[-1]}")

if remaining:
    away = [r for r in remaining if f"/{regions[1]}/" in r]
    niche = [r for r in remaining if r.startswith("athena/")]
    msg = (f"INCOMPLETE decommission — {len(remaining)} left: {remaining}. "
           + (f"Cross-region orphans (swept one region): {away}. " if away else "")
           + (f"Niche Athena work-groups left: {niche}." if niche else ""))
    fail(msg)

print(f"OK: nothing carrying '{prefix}' remains across {regions[0]} + {regions[1]} "
      "(Athena/Secrets/SSM/SQS all clean)")
sys.exit(0)
