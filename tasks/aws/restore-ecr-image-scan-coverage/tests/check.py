"""Check that every application repository is scanned on push and its findings are routed.

Passes when no seeded repository was replaced, registry scanning rules in both regions
cover the application and other-team repositories but not the mirror with scan type BASIC,
and an enabled EventBridge rule that the SNS topic policy admits forwards every completed
scan to the security topic.
"""
import fnmatch
import json

import checkkit as ck

seed = ck.seed()
REGION = seed["region"]
APPS = seed["app_repos"]
MIRROR = seed["mirror_repo"]
OTHERS = seed["other_team_repos"]
WEST = seed["west_region"]
WEST_APPS = seed["west_app_repos"]
TOPIC = seed["topic_arn"]

ecr = ck.client("ecr")
events = ck.client("events")
sns = ck.client("sns")
ecr_w = ck.client("ecr", region_name=WEST)

# Every seeded repository must still exist and not have been replaced.
present = {}
for name, ident in seed["repo_identity"].items():
    cli = ecr_w if ident.get("region") == WEST else ecr
    try:
        d = cli.describe_repositories(repositoryNames=[name])["repositories"][0]
    except Exception as exc:  # noqa: BLE001
        ck.fail(f"repository {name} no longer exists ({type(exc).__name__}); the task states "
                f"that no repository may be deleted or replaced")
    if d["repositoryArn"] != ident["repositoryArn"] or d["createdAt"].isoformat() != ident["createdAt"]:
        ck.fail(f"repository {name} was replaced: seeded arn/createdAt "
                f"{ident['repositoryArn']} / {ident['createdAt']}, now "
                f"{d['repositoryArn']} / {d['createdAt'].isoformat()}")
    if (d.get("encryptionConfiguration", {}) != ident["encryptionConfiguration"]
            or d.get("imageTagMutability") != ident["imageTagMutability"]):
        ck.fail(f"repository {name} was rebuilt with different settings: seeded "
                f"{ident['encryptionConfiguration']}/{ident['imageTagMutability']}, now "
                f"{d.get('encryptionConfiguration')}/{d.get('imageTagMutability')}")
    present[name] = d

# Registry scanning coverage.
cfg = ecr.get_registry_scanning_configuration()["scanningConfiguration"]
scan_type = cfg.get("scanType")
rules = cfg.get("rules", [])

ck.require(
    scan_type == "BASIC",
    f"the registry scan type is {scan_type!r}; the task states that Amazon Inspector and "
    f"enhanced scanning must not be enabled for this registry",
)


def auto_scanned(repo, ruleset=None):
    """Return the registry scanning filters that match this repository.

    Only registry rules are considered; the repository-level scanOnPush flag is stored
    independently and does not enable automatic scanning.
    """
    hits = []
    for rule in (rules if ruleset is None else ruleset):
        if rule.get("scanFrequency") not in ("SCAN_ON_PUSH", "CONTINUOUS_SCAN"):
            continue
        for f in rule.get("repositoryFilters", []):
            pat = f.get("filter", "")
            if fnmatch.fnmatchcase(repo, pat) or fnmatch.fnmatchcase(repo, pat + "*"):
                hits.append(pat)
    return hits


flags = {r: present[r].get("imageScanningConfiguration", {}).get("scanOnPush") for r in present}
uncovered = [r for r in APPS if not auto_scanned(r)]
if uncovered:
    ck.fail(
        f"these application repositories are still not scanned automatically on push: "
        f"{uncovered}. GetRegistryScanningConfiguration returns scanType={scan_type} with "
        f"rules={json.dumps(rules)}, and no SCAN_ON_PUSH filter matches them, so each is left "
        f"on the manual scan frequency. Their repository-level scanOnPush flags currently read "
        f"{json.dumps({r: flags[r] for r in uncovered})}, which is the independent legacy "
        f"per-repository setting and does not put a repository on automatic scanning."
    )

cfg_w = ecr_w.get_registry_scanning_configuration()["scanningConfiguration"]
rules_w = cfg_w.get("rules", [])
ck.require(
    cfg_w.get("scanType") == "BASIC",
    f"the registry scan type in {WEST} is {cfg_w.get('scanType')!r}; the task states that "
    f"Amazon Inspector and enhanced scanning must not be enabled",
)
uncovered_w = [r for r in WEST_APPS if not auto_scanned(r, rules_w)]
if uncovered_w:
    ck.fail(
        f"these application repositories are still not scanned automatically on push: "
        f"{uncovered_w}. They live in {WEST}, which has its own registry scanning "
        f"configuration: GetRegistryScanningConfiguration in {WEST} returns "
        f"rules={json.dumps(rules_w)}, so nothing there matches them and each is left on the "
        f"manual scan frequency. Their repository-level scanOnPush flags read "
        f"{json.dumps({r: present[r].get('imageScanningConfiguration', {}).get('scanOnPush') for r in uncovered_w})}. "
        f"Fixing the configuration in {seed['region']} has no effect on them: the two registries "
        f"are configured independently."
    )

dropped = [r for r in OTHERS if not auto_scanned(r)]
if dropped:
    ck.fail(
        f"these repositories are no longer scanned automatically on push: {dropped}. They are "
        f"not owned by this team and were covered when the task started, by a filter in the "
        f"same single SCAN_ON_PUSH rule that had to be rewritten. GetRegistryScanningConfiguration "
        f"now returns rules={json.dumps(rules)}, and no filter in it matches them, so rewriting "
        f"that rule removed their coverage."
    )

mirror_hits = auto_scanned(MIRROR)
ck.require(
    not mirror_hits,
    f"{MIRROR} is now scanned automatically on push: registry scanning filter(s) "
    f"{mirror_hits} match it. The task states it is the one repository that must not be "
    f"scanned automatically.",
)

# Scan events from every application repository must reach the security topic.
try:
    sns.get_topic_attributes(TopicArn=TOPIC)
except Exception as exc:  # noqa: BLE001
    ck.fail(f"the security topic {TOPIC} no longer exists ({type(exc).__name__})")

matching_rules = []
paginator = events.get_paginator("list_rules")
for page in paginator.paginate(EventBusName="default"):
    for rule in page["Rules"]:
        targets = events.list_targets_by_rule(Rule=rule["Name"], EventBusName="default")["Targets"]
        if any(t["Arn"] == TOPIC for t in targets):
            matching_rules.append(rule)

ck.require(
    matching_rules,
    f"no enabled EventBridge rule on the default bus targets {TOPIC}, so scan findings "
    f"cannot reach the security topic",
)


def scan_event(repo, severities):
    return {
        "id": "11111111-2222-3333-4444-555555555555",
        "version": "0",
        "account": seed["account"],
        "time": "2026-01-01T00:00:00Z",
        "region": REGION,
        "source": "aws.ecr",
        "detail-type": "ECR Image Scan",
        "resources": [f"arn:aws:ecr:{REGION}:{seed['account']}:repository/{repo}"],
        "detail": {
            "scan-status": "COMPLETE",
            "repository-name": repo,
            "image-digest": "sha256:" + "a" * 64,
            "image-tags": ["release-1"],
            "finding-severity-counts": severities,
        },
    }


def routing_rule(repo):
    """Return a rule that matches completed scans for this repository, with or without findings."""
    probes = [scan_event(repo, {"HIGH": 1, "MEDIUM": 2}), scan_event(repo, {})]
    for rule in matching_rules:
        if rule.get("State") != "ENABLED" or not rule.get("EventPattern"):
            continue
        if all(events.test_event_pattern(EventPattern=rule["EventPattern"],
                                         Event=json.dumps(ev))["Result"] for ev in probes):
            return rule
    return None


routers = {r: routing_rule(r) for r in APPS}
unrouted = [r for r in APPS if not routers[r]]
ck.require(
    not unrouted,
    f"a completed image scan for these application repositories is not forwarded to {TOPIC}: "
    f"{unrouted}. Tested with EventBridge TestEventPattern, using both a completed scan with "
    f"findings and a completed scan with none, against every enabled rule on the default bus "
    f"that targets the topic: "
    f"{json.dumps({r['Name']: r.get('EventPattern') for r in matching_rules})}",
)

router_arns = {r["Arn"] for r in routers.values() if r}
policy = json.loads(sns.get_topic_attributes(TopicArn=TOPIC)["Attributes"].get("Policy", "{}"))


def admits_router(statement):
    """True if the statement lets the routing rules publish, including aws:SourceArn conditions."""
    if statement.get("Effect") != "Allow":
        return False
    if "events.amazonaws.com" not in ck.as_list(statement.get("Principal", {}).get("Service", [])):
        return False
    if not any(a.lower() in ("sns:publish", "sns:*") for a in ck.as_list(statement.get("Action", []))):
        return False
    for op, keys in statement.get("Condition", {}).items():
        for key, vals in keys.items():
            if key.lower() != "aws:sourcearn":
                continue
            vals = ck.as_list(vals)
            if op.lower().startswith("arnlike") or op.lower().startswith("stringlike"):
                if not any(fnmatch.fnmatchcase(a, v) for a in router_arns for v in vals):
                    return False
            elif not router_arns & set(vals):
                return False
    return True


ck.require(
    any(admits_router(st) for st in policy.get("Statement", [])),
    f"{TOPIC} does not allow the rule(s) doing the routing ({sorted(router_arns)}) to publish "
    f"to it, so a matched finding would be dropped at delivery. Current policy: "
    f"{json.dumps(policy)}",
)

ck.ok(f"all {len(APPS) + len(WEST_APPS)} application repositories are scanned automatically "
      f"on push in both registries, the "
      f"data-platform repositories kept theirs, "
      f"{MIRROR} is not, and findings from all of them reach {TOPIC}")
