"""Check that every EventBridge rule tagged App=intake is enabled and no other rule changed.

Passes when the seeded intake rules are enabled and still tagged, every rule tagged
App=intake on any bus in any region is enabled, and the remaining rules recorded at setup
keep their original state.
"""
import boto3
import checkkit as ck

seed = ck.seed()
home = seed["home_region"]
other = seed["other_region"]
intake = seed["intake"]
decoy = seed["decoy"]
others = seed.get("others") or []


def client(region):
    return boto3.client("events", region_name=region)


def tags_of(ev, arn):
    tags = ev.list_tags_for_resource(ResourceARN=arn).get("Tags") or []
    return {t.get("Key"): t.get("Value") for t in tags}


def bus_kw(bus):
    if bus and bus != "default":
        return {"EventBusName": bus}
    return {}


def list_buses(ev):
    return [b.get("Name") for b in (ev.list_event_buses().get("EventBuses") or []) if b.get("Name")]


def list_all_rules(ev, bus):
    out = []
    token = None
    while True:
        kw = bus_kw(bus)
        if token:
            kw["NextToken"] = token
        resp = ev.list_rules(**kw)
        out.extend(resp.get("Rules") or [])
        token = resp.get("NextToken")
        if not token:
            break
    return out


def all_regions():
    seeded = seed.get("regions") or []
    out = []
    for r in seeded:
        if r and r not in out:
            out.append(r)
    try:
        ec2 = boto3.client("ec2")
        for r in ec2.describe_regions().get("Regions") or []:
            name = r.get("RegionName")
            if name and name not in out:
                out.append(name)
    except Exception:
        pass
    if home not in out:
        out.append(home)
    if other not in out:
        out.append(other)
    return out


seen = set()
for item in intake:
    region = item["region"]
    name = item["name"]
    bus = item.get("bus") or "default"
    ev = client(region)
    desc = ev.describe_rule(Name=name, **bus_kw(bus))
    ck.require(desc.get("Name") == name, "missing intake rule")
    ck.require((desc.get("State") or "") == "ENABLED", "an intake rule is not enabled")
    arn = desc.get("Arn")
    ck.require(tags_of(ev, arn).get("App") == "intake", "an intake rule lost its App tag")
    seen.add((region, bus, name))

dev = client(decoy["region"])
dd = dev.describe_rule(Name=decoy["name"], **bus_kw(decoy.get("bus") or "default"))
ck.require(dd.get("Name") == decoy["name"], "decoy rule missing")
ck.require((dd.get("State") or "") == "DISABLED", "a non-intake rule was changed")

for region in all_regions():
    ev = client(region)
    try:
        buses = list_buses(ev)
    except Exception:
        continue
    for bus in buses:
        try:
            rules = list_all_rules(ev, bus)
        except Exception:
            continue
        for r in rules:
            name = r.get("Name")
            arn = r.get("Arn")
            if not name or not arn:
                continue
            try:
                tag = tags_of(ev, arn).get("App")
            except Exception:
                continue
            if tag != "intake":
                continue
            ck.require((r.get("State") or "") == "ENABLED", "a tagged intake rule is not enabled")
            seen.add((region, bus, name))

ck.require(len(seen) >= 3, "not every tagged intake rule was found")

for item in others:
    region = item["region"]
    name = item["name"]
    bus = item.get("bus") or "default"
    ev = client(region)
    desc = ev.describe_rule(Name=name, **bus_kw(bus))
    ck.require(desc.get("Name") == name, "a non-intake rule is missing")
    ck.require((desc.get("State") or "") == (item.get("state") or ""), "a non-intake rule was changed")

ck.ok("intake rules enabled")
