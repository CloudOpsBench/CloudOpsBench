#!/usr/bin/env bash
# Removes rules left by earlier runs, then creates EventBridge rules tagged App=intake
# (one enabled and one disabled on the default bus, one disabled on a custom bus in a
# second region) and a disabled rule tagged App=drill. Records the rules and the state
# of every other rule in seed_state.json.
set -euo pipefail
python3 <<'PY'
import json, os, random, subprocess, sys, time

acct = subprocess.check_output(["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"], text=True).strip()
home = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
other = "us-west-2" if home != "us-west-2" else "us-east-1"
suf = str(random.randint(10000, 99999))
pattern = json.dumps({"source": ["intake.ops"]})

def run(region, *args, check=True):
    p = subprocess.run(["aws", *args, "--region", region], capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.stderr.write(p.stderr or p.stdout or "aws failed\n")
        raise SystemExit(p.returncode or 1)
    return p

def aws(region, *args, check=True):
    return (run(region, *args, check=check).stdout or "").strip()

def aws_json(region, *args, check=True):
    raw = aws(region, *args, check=check)
    return json.loads(raw) if raw else {}

def rule_arn(region, name, bus="default"):
    if not bus or bus == "default":
        return f"arn:aws:events:{region}:{acct}:rule/{name}"
    return f"arn:aws:events:{region}:{acct}:rule/{bus}/{name}"

def list_buses(region):
    return [b.get("Name") for b in (aws_json(region, "events", "list-event-buses", "--output", "json", check=False).get("EventBuses") or []) if b.get("Name")]

def list_rules(region, bus="default"):
    out = []
    token = None
    while True:
        args = ["events", "list-rules", "--output", "json"]
        if bus and bus != "default":
            args.extend(["--event-bus-name", bus])
        if token:
            args.extend(["--next-token", token])
        listed = aws_json(region, *args, check=False)
        out.extend(listed.get("Rules") or [])
        token = listed.get("NextToken")
        if not token:
            break
    return out

def tags_of(region, arn):
    tags = aws_json(region, "events", "list-tags-for-resource", "--resource-arn", arn, "--output", "json", check=False).get("Tags") or []
    return {t.get("Key"): t.get("Value") for t in tags}

listed = aws_json(home, "ec2", "describe-regions", "--query", "Regions[].RegionName", "--output", "json", check=False)
if isinstance(listed, str):
    listed = [listed]
if not isinstance(listed, list) or not listed:
    listed = [home, other]
regions = []
for r in listed:
    if r and r not in regions:
        regions.append(r)
if home not in regions:
    regions.append(home)
if other not in regions:
    regions.append(other)

def wipe(region):
    for bus in list_buses(region):
        for r in list_rules(region, bus):
            name = r.get("Name") or ""
            arn = r.get("Arn") or rule_arn(region, name, bus)
            kv = tags_of(region, arn)
            own = kv.get("App") in ("intake", "drill") or name.startswith("intake-") or name.startswith("drill-") or name.startswith("fwd-")
            if not own:
                continue
            ids = aws(region, "events", "list-targets-by-rule", "--rule", name, "--event-bus-name", bus, "--query", "Targets[].Id", "--output", "text", check=False)
            if ids:
                run(region, "events", "remove-targets", "--rule", name, "--event-bus-name", bus, "--ids", *ids.split(), "--force", check=False)
            run(region, "events", "delete-rule", "--name", name, "--event-bus-name", bus, "--force", check=False)
        if bus != "default" and (bus.startswith("mesh-") or bus.startswith("intake-bus-")):
            run(region, "events", "delete-event-bus", "--name", bus, check=False)

for region in regions:
    wipe(region)
time.sleep(1)

def put_rule(region, name, state, tag, bus="default"):
    args = ["events", "put-rule", "--name", name, "--event-pattern", pattern, "--state", state]
    if bus and bus != "default":
        args.extend(["--event-bus-name", bus])
    aws(region, *args)
    aws(region, "events", "tag-resource", "--resource-arn", rule_arn(region, name, bus), "--tags", f"Key=App,Value={tag}")

a = f"intake-{suf}-a"
b = f"intake-{suf}-b"
c = f"fwd-{suf}"
d = f"drill-{suf}-n"
bus = f"mesh-{suf}"
aws(other, "events", "create-event-bus", "--name", bus)
put_rule(home, a, "ENABLED", "intake")
put_rule(home, b, "DISABLED", "intake")
put_rule(home, d, "DISABLED", "drill")
put_rule(other, c, "DISABLED", "intake", bus)

others = []
for region in regions:
    for busn in list_buses(region):
        for r in list_rules(region, busn):
            name = r.get("Name") or ""
            arn = r.get("Arn") or rule_arn(region, name, busn)
            if not name:
                continue
            if tags_of(region, arn).get("App") == "intake":
                continue
            others.append({
                "name": name,
                "region": region,
                "bus": busn,
                "state": r.get("State") or "",
                "arn": arn,
            })

json.dump({
    "home_region": home,
    "other_region": other,
    "regions": regions,
    "intake": [
        {"name": a, "region": home, "bus": "default"},
        {"name": b, "region": home, "bus": "default"},
        {"name": c, "region": other, "bus": bus},
    ],
    "decoy": {"name": d, "region": home, "bus": "default"},
    "others": others,
}, open("seed_state.json", "w"))
print("seeded", a, b, c, d, bus, home, other)
PY
