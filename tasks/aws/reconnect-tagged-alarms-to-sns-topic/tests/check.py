"""Check that every alarm tagged App=nightbell notifies its region's App=nightbell SNS topic.

Passes when the tagged topics still exist with their tag, every tagged metric or composite
alarm in any region has its region's tagged topic as an alarm action and keeps its tag,
and all other alarms keep their configuration and tags.
"""
import boto3
import checkkit as ck

seed = ck.seed()
home = seed.get("home_region") or "us-east-1"


def cw(region):
    return boto3.client("cloudwatch", region_name=region)


def sns(region):
    return boto3.client("sns", region_name=region)


def tags_of(region, arn):
    if not arn:
        return {}
    try:
        tags = cw(region).list_tags_for_resource(ResourceARN=arn).get("Tags") or []
    except Exception:
        return {}
    return {t.get("Key"): t.get("Value") for t in tags}


def sns_tags(region, arn):
    if not arn:
        return {}
    try:
        tags = sns(region).list_tags_for_resource(ResourceArn=arn).get("Tags") or []
    except Exception:
        return {}
    return {t.get("Key"): t.get("Value") for t in tags}


def list_alarms(region, typ):
    out = []
    token = None
    key = "CompositeAlarms" if typ == "CompositeAlarm" else "MetricAlarms"
    while True:
        kw = {"AlarmTypes": [typ]}
        if token:
            kw["NextToken"] = token
        try:
            body = cw(region).describe_alarms(**kw)
        except Exception:
            return out
        out.extend(body.get(key) or [])
        token = body.get("NextToken")
        if not token:
            break
    return out


def list_topics(region):
    out = []
    token = None
    while True:
        kw = {}
        if token:
            kw["NextToken"] = token
        try:
            body = sns(region).list_topics(**kw)
        except Exception:
            return out
        out.extend(body.get("Topics") or [])
        token = body.get("NextToken")
        if not token:
            break
    return out


def all_regions():
    out = []
    for name in seed.get("regions") or []:
        if name and name not in out:
            out.append(name)
    for name in (home, seed.get("other_region")):
        if name and name not in out:
            out.append(name)
    try:
        for r in boto3.client("ec2", region_name=home).describe_regions().get("Regions") or []:
            name = r.get("RegionName")
            if name and name not in out:
                out.append(name)
    except Exception:
        pass
    return out


def get_named(region, name, typ):
    key = "CompositeAlarms" if typ == "CompositeAlarm" else "MetricAlarms"
    try:
        body = cw(region).describe_alarms(AlarmNames=[name], AlarmTypes=[typ])
    except Exception:
        return {}
    items = body.get(key) or []
    return items[0] if items else {}


def num(v):
    if v is None:
        return v
    try:
        from decimal import Decimal
        if isinstance(v, Decimal):
            v = float(v)
    except Exception:
        pass
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


def tagged_topics():
    found = {}
    for region in all_regions():
        arns = []
        for t in list_topics(region):
            arn = t.get("TopicArn") or ""
            if sns_tags(region, arn).get("App") == "nightbell":
                arns.append(arn)
        if arns:
            found[region] = arns
    return found


for item in seed.get("topics") or []:
    region = item.get("region") or home
    arn = item.get("arn") or ""
    live = False
    try:
        sns(region).get_topic_attributes(TopicArn=arn)
        live = True
    except Exception:
        live = False
    ck.require(live, "the tagged topic is missing")
    ck.require(sns_tags(region, arn).get("App") == "nightbell", "the tagged topic lost its App tag")

topics = tagged_topics()
ck.require(topics, "the tagged topic is missing")

for item in seed["nightbell"]:
    region = item.get("region") or home
    want = item.get("topic") or ((topics.get(region) or [None])[0])
    a = get_named(region, item["name"], item["type"])
    ck.require(a.get("AlarmName") == item["name"], "a tagged alarm is missing")
    ck.require(want in (a.get("AlarmActions") or []), "a tagged alarm still has no notify action")
    ck.require(tags_of(region, a.get("AlarmArn")).get("App") == "nightbell", "a tagged alarm lost its App tag")

decoy = seed["decoy"]
decoy_region = decoy.get("region") or home
a = get_named(decoy_region, decoy["name"], decoy["type"])
ck.require(a.get("AlarmName") == decoy["name"], "an untagged alarm is missing")
ck.require(config_of(a, decoy["type"]) == decoy.get("config"), "an untagged alarm was changed")
ck.require(tags_of(decoy_region, a.get("AlarmArn")) == (decoy.get("tags") or {"App": "drill"}), "an untagged alarm was retagged")

seen = set()
for region in all_regions():
    regional = topics.get(region) or []
    for typ in ("MetricAlarm", "CompositeAlarm"):
        for a in list_alarms(region, typ):
            if tags_of(region, a.get("AlarmArn")).get("App") != "nightbell":
                continue
            actions = a.get("AlarmActions") or []
            ck.require(any(t in actions for t in regional), "a tagged alarm still has no notify action")
            seen.add((region, a.get("AlarmName")))

ck.require(len(seen) >= 3, "not every tagged alarm was found")

for other in seed.get("others") or []:
    region = other.get("region") or home
    a = get_named(region, other["name"], other["type"])
    ck.require(a.get("AlarmName") == other.get("name"), "an unrelated alarm is missing")
    ck.require(config_of(a, other["type"]) == other.get("config"), "an unrelated alarm was changed")
    if other.get("tags") is not None:
        ck.require(tags_of(region, a.get("AlarmArn")) == other.get("tags"), "an unrelated alarm was retagged")

ck.ok("nightbell notify")
