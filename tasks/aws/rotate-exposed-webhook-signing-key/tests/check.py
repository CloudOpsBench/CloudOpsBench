"""Check that the exposed signing key is no longer served and every workload uses the new one.

Passes when the secret holds a new key under signing_key, no version stage on it returns
the exposed value, every active revision of every seeded relay-webhook-* task definition
family in both regions resolves that same new key from a Secrets Manager secret, and the
payouts secret keeps its seeded value and version stages.
"""
import json

import checkkit as ck

seed = ck.seed()
EAST = seed["region"]
WEST = seed["west_region"]
sm = {EAST: ck.client("secretsmanager", region_name=EAST),
      WEST: ck.client("secretsmanager", region_name=WEST)}
ecs = {EAST: ck.client("ecs", region_name=EAST),
       WEST: ck.client("ecs", region_name=WEST)}

NAME = seed["secret_name"]
EXPOSED = seed["exposed_value"]
EAST_ARN = seed["secret_arn"]


def secret_string(secret_id, region, **kw):
    try:
        return sm[region].get_secret_value(SecretId=secret_id, **kw)["SecretString"]
    except Exception:
        name = secret_id.split(":")[-1] if secret_id.startswith("arn:") else None
        if name:
            try:
                return sm[region].get_secret_value(SecretId=name, **kw)["SecretString"]
            except Exception:
                pass
        return None


def json_key(text, key):
    """Return what ECS hands the container: the named JSON key, or the whole string."""
    if not key:
        return text
    try:
        return json.loads(text).get(key)
    except Exception:
        return None


# The current value of the us-east-1 secret defines the new key.
current = secret_string(EAST_ARN, EAST)
ck.require(current is not None,
           "the secret %s in %s no longer returns a value. instruction.md requires that it "
           "hold a new signing key in a JSON object under signing_key." % (NAME, EAST))
NEW = json_key(current, "signing_key")
ck.require(isinstance(NEW, str) and NEW.strip(),
           "the secret %s does not hold a signing key: its signing_key field is %s. "
           "instruction.md requires it to keep the JSON shape with the key under "
           "signing_key." % (NAME, "missing" if NEW is None else "empty"))
ck.require(EXPOSED not in current,
           "the secret %s still returns the exposed signing key as its current value. "
           "instruction.md requires it to return a new signing key. The exposed value is "
           "the one the secret held when the task started, readable then with a plain "
           "get_secret_value." % NAME)

# Every version stage the us-east-1 secret still carries.
stages = sorted({st for sts in sm[EAST].describe_secret(SecretId=EAST_ARN)
                 ["VersionIdsToStages"].values() for st in sts})
for stage in stages:
    got = secret_string(EAST_ARN, EAST, VersionStage=stage)
    if got and EXPOSED in got:
        ck.fail(
            "the exposed signing key is still obtainable from %s under version stage %s. "
            "instruction.md requires that no version stage on that secret return the "
            "exposed value. Replacing a secret's value moves the old version to "
            "AWSPREVIOUS, which keeps serving it; describe_secret's VersionIdsToStages "
            "lists every stage still attached, and update_secret_version_stage detaches "
            "one. Stages present: %s." % (NAME, stage, ", ".join(stages)))


def parse_ref(ref, home_region):
    """Split an ECS valueFrom into (secret_id, region, json key, stage, version)."""
    if ref.startswith("arn:"):
        parts = ref.split(":")
        secret_id = ":".join(parts[:7])
        region = parts[3] or home_region
        tail = parts[7:]
    else:                               # bare-name form resolves in the task's own region
        parts = ref.split(":")
        secret_id, region, tail = parts[0], home_region, parts[1:]
    key = tail[0] if len(tail) > 0 and tail[0] else None
    stage = tail[1] if len(tail) > 1 and tail[1] else None
    version = tail[2] if len(tail) > 2 and tail[2] else None
    return secret_id, region, key, stage, version


def audit(what, region, listed_by, ref):
    """Fail unless this valueFrom resolves to the new key and not the exposed one."""
    secret_id, sregion, key, stage, version = parse_ref(ref, region)
    if sregion not in sm:
        ck.fail("%s reads WEBHOOK_SIGNING_KEY from valueFrom %s, which points at region "
                "%s where nothing was seeded. instruction.md requires every workload to "
                "resolve the same new key from a Secrets Manager secret."
                % (what, ref, sregion))
    if version:
        raw, how = secret_string(secret_id, sregion, VersionId=version), \
            "version id %s" % version
    elif stage:
        raw, how = secret_string(secret_id, sregion, VersionStage=stage), \
            "version stage %s" % stage
    else:
        raw, how = secret_string(secret_id, sregion), "the current value"
    delivered = json_key(raw, key)
    if key is None and delivered != NEW:
        blob_key = json_key(raw, "signing_key")
        if blob_key == NEW:
            delivered = blob_key
    if raw and EXPOSED in raw:
        ck.fail(
            "%s still resolves to the exposed signing key. It reads WEBHOOK_SIGNING_KEY "
            "from valueFrom %s, which resolves %s of the secret in %s, and that serves the "
            "exposed value no matter what the us-east-1 secret's current value is: a "
            "version keeps serving its own contents even after its stages are removed, "
            "and a standalone secret in another region has its own version history. This "
            "workload was listable for the whole rollout with %s, the execution role's "
            "policy grants secretsmanager:GetSecretValue on "
            "arn:aws:secretsmanager:*:<account>:secret:relay-webhook-signing-key-* in "
            "every region, and instruction.md puts every ECS task definition family named "
            "relay-webhook-* in scope, with no region qualifier."
            % (what, ref, how, sregion, listed_by))
    ck.require(
        isinstance(delivered, str) and delivered.strip() and delivered == NEW,
        "%s does not resolve to the same new signing key the us-east-1 secret returns. It "
        "reads WEBHOOK_SIGNING_KEY from valueFrom %s, which resolves %s of the secret in "
        "%s and delivers %s. It was listable with %s. instruction.md requires every "
        "workload that reads the signing key to resolve the same new key and to keep "
        "reading it from a Secrets Manager secret."
        % (what, ref, how, sregion,
           "nothing" if delivered is None else "a different value", listed_by))


for region, families in ((EAST, seed["east_families"]), (WEST, seed["west_families"])):
    for family in families:
        listed_by = ("ecs:ListTaskDefinitions(status=ACTIVE) on the family in %s"
                     % region)
        active = ecs[region].list_task_definitions(
            familyPrefix=family, status="ACTIVE").get("taskDefinitionArns", [])
        for rev_arn in active:
            rtd = ecs[region].describe_task_definition(
                taskDefinition=rev_arn)["taskDefinition"]
            rev_refs = [entry for c in rtd.get("containerDefinitions", [])
                        for entry in c.get("secrets", []) if entry.get("valueFrom")]
            ck.require(rev_refs,
                       "the active ECS revision %s in %s no longer reads the signing key "
                       "from a secret. instruction.md requires every revision that stays "
                       "active to resolve the same new key and to keep reading it from a "
                       "Secrets Manager secret; deregistering a revision is the way to "
                       "retire it." % (rev_arn.rsplit("/", 1)[1], region))
            for entry in rev_refs:
                audit("the active ECS revision %s in %s"
                      % (rev_arn.rsplit("/", 1)[1], region),
                      region, listed_by, entry["valueFrom"])
        try:
            td = ecs[region].describe_task_definition(
                taskDefinition=family)["taskDefinition"]
        except Exception:
            ck.fail(
                "the ECS task definition family %s in %s has no active revision. It read "
                "the signing key when the task started. instruction.md requires every "
                "workload that reads the key to keep reading it from a Secrets Manager "
                "secret." % (family, region))
        refs = [s for c in td.get("containerDefinitions", [])
                for s in c.get("secrets", []) if s.get("valueFrom")]
        ck.require(refs,
                   "the latest active revision of the ECS family %s in %s (revision %s) no "
                   "longer reads the signing key from a secret. instruction.md requires "
                   "every workload that reads the key to keep reading it from a Secrets "
                   "Manager secret, so dropping the reference is not a way to satisfy it."
                   % (family, region, td.get("revision")))
        for entry in refs:
            audit("the latest active revision of the ECS family %s in %s (revision %s)"
                  % (family, region, td.get("revision")),
                  region, "ecs:DescribeTaskDefinition on the family in %s" % region,
                  entry["valueFrom"])

# The payouts team's secret: value and version stages.
other_now = secret_string(seed["other_arn"], EAST)
ck.require(other_now is not None and seed["other_value"] in other_now,
           "the secret %s no longer returns the value it was seeded with. instruction.md "
           "states it belongs to the payouts team and must stay exactly as it is."
           % seed["other_name"])
other_stages = {v: sorted(s) for v, s in
                sm[EAST].describe_secret(SecretId=seed["other_arn"])
                ["VersionIdsToStages"].items()}
seeded_stages = {v: sorted(s) for v, s in seed["other_stages"].items()}
ck.require(other_stages == seeded_stages,
           "the version stages on %s changed. instruction.md states that secret's value "
           "and version stages must stay exactly as they are. Seeded: %s. Now: %s."
           % (seed["other_name"], json.dumps(seeded_stages, sort_keys=True),
              json.dumps(other_stages, sort_keys=True)))

ck.ok("the exposed key is gone from every stage and every workload in both regions "
      "resolves the same new key")
