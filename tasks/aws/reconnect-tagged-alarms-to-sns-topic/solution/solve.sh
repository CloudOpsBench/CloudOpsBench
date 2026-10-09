#!/usr/bin/env bash
# For every alarm tagged App=nightbell in any region, add that region's
# App=nightbell SNS topic as an alarm action.
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
listed = aws_json("ec2", "describe-regions", "--query", "Regions[].RegionName", "--output", "json")
if isinstance(listed, str):
    listed = [listed]
if not isinstance(listed, list) or not listed:
    listed = [home]
regions = []
for name in listed:
    if name and name not in regions:
        regions.append(name)
if home not in regions:
    regions.append(home)

def tags_of(region, arn):
    tags = aws_json("cloudwatch", "list-tags-for-resource", "--resource-arn", arn, "--region", region, "--output", "json").get("Tags") or []
    return {t.get("Key"): t.get("Value") for t in tags}

def list_alarms(region, typ):
    out = []
    token = None
    while True:
        args = ["cloudwatch", "describe-alarms", "--alarm-types", typ, "--region", region, "--output", "json"]
        if token:
            args.extend(["--next-token", token])
        body = aws_json(*args)
        key = "CompositeAlarms" if typ == "CompositeAlarm" else "MetricAlarms"
        out.extend(body.get(key) or [])
        token = body.get("NextToken")
        if not token:
            break
    return out

topics = {}
for region in regions:
    for t in aws_json("sns", "list-topics", "--region", region, "--output", "json").get("Topics") or []:
        arn = t.get("TopicArn") or ""
        tags = aws_json("sns", "list-tags-for-resource", "--resource-arn", arn, "--region", region, "--output", "json").get("Tags") or []
        kv = {x.get("Key"): x.get("Value") for x in tags}
        if kv.get("App") == "nightbell":
            topics[region] = arn
            break
if not topics:
    raise SystemExit("no nightbell topic")

for region in regions:
    topic = topics.get(region)
    if not topic:
        continue
    for typ in ("MetricAlarm", "CompositeAlarm"):
        for a in list_alarms(region, typ):
            arn = a.get("AlarmArn") or ""
            if tags_of(region, arn).get("App") != "nightbell":
                continue
            actions = a.get("AlarmActions") or []
            if topic in actions:
                continue
            name = a.get("AlarmName")
            if typ == "CompositeAlarm":
                aws_ok(
                    "cloudwatch", "put-composite-alarm",
                    "--alarm-name", name,
                    "--alarm-rule", a.get("AlarmRule"),
                    "--alarm-actions", topic,
                    "--region", region,
                )
            else:
                aws_ok(
                    "cloudwatch", "put-metric-alarm",
                    "--alarm-name", name,
                    "--metric-name", a.get("MetricName"),
                    "--namespace", a.get("Namespace"),
                    "--statistic", a.get("Statistic"),
                    "--period", str(a.get("Period")),
                    "--threshold", str(a.get("Threshold")),
                    "--comparison-operator", a.get("ComparisonOperator"),
                    "--evaluation-periods", str(a.get("EvaluationPeriods")),
                    "--treat-missing-data", a.get("TreatMissingData") or "missing",
                    "--alarm-actions", topic,
                    "--region", region,
                )
print("nightbell wired")
PY
