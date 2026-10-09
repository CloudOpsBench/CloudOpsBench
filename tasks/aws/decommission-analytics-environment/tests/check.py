#!/usr/bin/env python3
"""ext_archit_decommission_analytics grader (bundle) — full-decommission completeness check.

State-only. PASS iff NOTHING carrying the prefix remains, swept across BOTH regions and ALL
services in scope (Athena work-groups, Secrets Manager, SSM, SQS). FAIL if anything is left —
most often the cross-region orphans (a single-region sweep misses them) or the niche Athena
work-group (agents almost never enumerate Athena). Setup always creates the obvious home-region
resources, so a no-op leaves them and fails. Reads ./seed_state.json (CWD) for the prefix + the
two regions. Exit 0 = PASS ("OK: ..."), non-zero = FAIL ("FAIL: ..." to stderr).
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
    # Athena work-groups (the niche service — agents almost never enumerate it)
    for wg in (aws(["athena", "list-work-groups"], region) or {}).get("WorkGroups", []):
        if prefix in wg.get("Name", ""):
            remaining.append(f"athena/{region}/{wg.get('Name')}")
    # Secrets Manager (default list excludes secrets pending deletion — soft-delete counts as gone)
    for s in (aws(["secretsmanager", "list-secrets"], region) or {}).get("SecretList", []):
        if prefix in s.get("Name", ""):
            remaining.append(f"secret/{region}/{s.get('Name')}")
    # SSM parameters (/aaq-<hex>/config and /aaq-<hex>/west — contain the prefix)
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
