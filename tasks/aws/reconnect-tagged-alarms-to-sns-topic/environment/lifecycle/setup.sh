#!/usr/bin/env bash
# Creates App=nightbell SNS topics in two regions and CloudWatch metric and
# composite alarms with that tag, some without an alarm action, plus an alarm
# tagged for another app. Records the expected state in seed_state.json.
set -euo pipefail
python3 <<'PY'
import json, os, random, subprocess, sys

home = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
other = "us-west-2" if home != "us-west-2" else "us-east-1"
suf = str(random.randint(10000, 99999))

def run(*args, check=True, region=None):
    r = region or home
    p = subprocess.run(["aws", *args, "--region", r], capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.stderr.write(p.stderr or p.stdout or "aws failed\n")
        raise SystemExit(p.returncode or 1)
    return p

def aws(*args, check=True, region=None):
    return (run(*args, check=check, region=region).stdout or "").strip()

def aws_json(*args, check=True, region=None):
    raw = aws(*args, check=check, region=region)
    return json.loads(raw) if raw else {}

def all_regions():
    out = []
    body = aws_json("ec2", "describe-regions", "--output", "json", check=False)
    for r in body.get("Regions") or []:
        name = r.get("RegionName")
        if name and name not in out:
            out.append(name)
    for name in (home, other):
        if name not in out:
            out.append(name)
    return out

def tags_of(arn, region=None):
    tags = aws_json("cloudwatch", "list-tags-for-resource", "--resource-arn", arn, "--output", "json", check=False, region=region).get("Tags") or []
    return {t.get("Key"): t.get("Value") for t in tags}

def sns_tags(arn, region=None):
    tags = aws_json("sns", "list-tags-for-resource", "--resource-arn", arn, "--output", "json", check=False, region=region).get("Tags") or []
    return {t.get("Key"): t.get("Value") for t in tags}

def list_alarms(typ, region=None):
    out = []
    token = None
    while True:
        args = ["cloudwatch", "describe-alarms", "--alarm-types", typ, "--output", "json"]
        if token:
            args.extend(["--next-token", token])
        body = aws_json(*args, check=False, region=region)
        key = "CompositeAlarms" if typ == "CompositeAlarm" else "MetricAlarms"
        out.extend(body.get(key) or [])
        token = body.get("NextToken")
        if not token:
            break
    return out

def num(v):
    if v is None:
        return v
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v

def config_of(a, typ):
    def acts(key):
        return list(a.get(key) or [])
    dims = []
    for d in a.get("Dimensions") or []:
        dims.append({"Name": d.get("Name"), "Value": d.get("Value")})
    dims.sort(key=lambda d: (d.get("Name") or "", d.get("Value") or ""))
    out = {
        "actions": acts("AlarmActions"),
        "ok": acts("OKActions"),
        "insufficient": acts("InsufficientDataActions"),
        "description": a.get("AlarmDescription") or "",
    }
    if typ == "CompositeAlarm":
        out["rule"] = a.get("AlarmRule") or ""
    else:
        out["metric"] = a.get("MetricName")
        out["namespace"] = a.get("Namespace")
        out["statistic"] = a.get("Statistic")
        out["period"] = num(a.get("Period"))
        out["threshold"] = num(a.get("Threshold"))
        out["comparison"] = a.get("ComparisonOperator")
        out["evaluation"] = num(a.get("EvaluationPeriods"))
        out["missing"] = a.get("TreatMissingData") or "missing"
        out["dimensions"] = dims
    return out

def wipe():
    for region in all_regions():
        for typ in ("MetricAlarm", "CompositeAlarm"):
            for a in list_alarms(typ, region=region):
                name = a.get("AlarmName") or ""
                arn = a.get("AlarmArn") or ""
                kv = tags_of(arn, region=region) if arn else {}
                own = kv.get("App") in ("nightbell", "drill") or name.startswith("nightbell-") or name.startswith("drill-") or name.startswith("keel-")
                if own:
                    run("cloudwatch", "delete-alarms", "--alarm-names", name, check=False, region=region)
        for t in aws_json("sns", "list-topics", "--output", "json", check=False, region=region).get("Topics") or []:
            arn = t.get("TopicArn") or ""
            kv = sns_tags(arn, region=region)
            if kv.get("App") == "nightbell" or (arn.split(":")[-1].startswith("nightbell-")):
                run("sns", "delete-topic", "--topic-arn", arn, check=False, region=region)

wipe()

metric = [
    "--metric-name", "ApproximateNumberOfMessagesVisible",
    "--namespace", "AWS/SQS",
    "--statistic", "Average",
    "--period", "300",
    "--threshold", "1",
    "--comparison-operator", "GreaterThanThreshold",
    "--evaluation-periods", "1",
    "--treat-missing-data", "notBreaching",
]

home_topic = aws_json("sns", "create-topic", "--name", f"nightbell-{suf}", "--tags", "Key=App,Value=nightbell", "--output", "json")["TopicArn"]
other_topic = aws_json("sns", "create-topic", "--name", f"nightbell-{suf}", "--tags", "Key=App,Value=nightbell", "--output", "json", region=other)["TopicArn"]

m1 = f"nightbell-{suf}-a"
m2 = f"nightbell-{suf}-b"
d = f"drill-{suf}-n"
pulse = f"keel-{suf}-pulse"
c = f"keel-{suf}-fwd"

aws("cloudwatch", "put-metric-alarm", "--alarm-name", m1, "--alarm-actions", home_topic, "--tags", "Key=App,Value=nightbell", *metric)
aws("cloudwatch", "put-metric-alarm", "--alarm-name", m2, "--tags", "Key=App,Value=nightbell", *metric)
aws("cloudwatch", "put-metric-alarm", "--alarm-name", d, "--tags", "Key=App,Value=drill", *metric)
aws("cloudwatch", "put-metric-alarm", "--alarm-name", pulse, *metric, region=other)
aws("cloudwatch", "put-composite-alarm", "--alarm-name", c, "--alarm-rule", f"ALARM({pulse})", "--tags", "Key=App,Value=nightbell", region=other)

def snap_alarm(name, typ, region, topic_arn):
    key = "CompositeAlarms" if typ == "CompositeAlarm" else "MetricAlarms"
    body = aws_json("cloudwatch", "describe-alarms", "--alarm-names", name, "--alarm-types", typ, "--output", "json", check=False, region=region)
    items = body.get(key) or []
    a = items[0] if items else {}
    return {
        "name": name,
        "type": typ,
        "region": region,
        "topic": topic_arn,
        "arn": a.get("AlarmArn") or "",
        "config": config_of(a, typ),
        "tags": tags_of(a.get("AlarmArn") or "", region=region),
    }

skip = {m1, m2, c, d}
others = []
for region in all_regions():
    for typ in ("MetricAlarm", "CompositeAlarm"):
        for a in list_alarms(typ, region=region):
            name = a.get("AlarmName") or ""
            if name in skip:
                continue
            kv = tags_of(a.get("AlarmArn") or "", region=region)
            if kv.get("App") == "nightbell":
                continue
            others.append({
                "name": name,
                "type": typ,
                "region": region,
                "config": config_of(a, typ),
                "tags": kv,
            })

json.dump({
    "home_region": home,
    "other_region": other,
    "topic": home_topic,
    "topics": [
        {"arn": home_topic, "region": home, "tags": sns_tags(home_topic, region=home)},
        {"arn": other_topic, "region": other, "tags": sns_tags(other_topic, region=other)},
    ],
    "regions": all_regions(),
    "nightbell": [
        snap_alarm(m1, "MetricAlarm", home, home_topic),
        snap_alarm(m2, "MetricAlarm", home, home_topic),
        snap_alarm(c, "CompositeAlarm", other, other_topic),
    ],
    "decoy": snap_alarm(d, "MetricAlarm", home, ""),
    "others": others,
}, open("seed_state.json", "w"))
print("seeded", home_topic, other_topic, m1, m2, c, d, pulse)
PY
