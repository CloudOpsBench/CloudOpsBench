#!/usr/bin/env bash
set -euo pipefail
python3 <<'PY'
import json, os, subprocess, sys

def run(*args):
    return subprocess.run(["aws", *args], capture_output=True, text=True)

def aws(*args):
    p = run(*args)
    return (p.stdout or "").strip() if p.returncode == 0 else ""

def aws_ok(*args):
    p = run(*args)
    if p.returncode != 0:
        sys.stderr.write((p.stderr or p.stdout or "aws failed") + "\n")
        raise SystemExit(p.returncode or 1)
    return (p.stdout or "").strip()

def aws_json(*args):
    raw = aws(*args)
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        i, j = raw.find("{"), raw.rfind("}")
        return json.loads(raw[i:j+1]) if i >= 0 and j > i else {}

home = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
regions = aws_json("ec2", "describe-regions", "--query", "Regions[].RegionName", "--output", "json")
if isinstance(regions, str):
    regions = [regions]
if not isinstance(regions, list) or not regions:
    other = "us-west-2" if home != "us-west-2" else "us-east-1"
    regions = [home, other]

def list_buses(region):
    return [b.get("Name") for b in (aws_json("events", "list-event-buses", "--region", region, "--output", "json").get("EventBuses") or []) if b.get("Name")]

def list_rules(region, bus):
    out = []
    token = None
    while True:
        args = ["events", "list-rules", "--region", region, "--output", "json"]
        if bus and bus != "default":
            args.extend(["--event-bus-name", bus])
        if token:
            args.extend(["--next-token", token])
        listed = aws_json(*args)
        out.extend(listed.get("Rules") or [])
        token = listed.get("NextToken")
        if not token:
            break
    return out

for region in regions:
    for bus in list_buses(region):
        for r in list_rules(region, bus):
            name = r.get("Name")
            if not name:
                continue
            arn = r.get("Arn") or ""
            tags = aws_json("events", "list-tags-for-resource", "--resource-arn", arn, "--region", region, "--output", "json").get("Tags") or []
            kv = {t.get("Key"): t.get("Value") for t in tags}
            if kv.get("App") != "intake":
                continue
            if (r.get("State") or "") == "ENABLED":
                continue
            args = ["events", "enable-rule", "--name", name, "--region", region]
            if bus and bus != "default":
                args.extend(["--event-bus-name", bus])
            aws_ok(*args)
print("intake rules enabled")
PY
