"""Grader for audit-relay-coverage-task. Exit 0 = PASS.

Outcome first: everything the prompt asks for is proved by writing real log events and
reading the audit streams. The structural checks that follow only enforce the prompt's
restraints; none of them encodes why delivery would or would not work.
"""
import gzip
import json
import secrets
import time

import checkkit as ck

seed = ck.seed()
REGION = seed["region"]
WEST = seed["west_region"]
RELAYED = {REGION: list(seed["relayed_groups"]), WEST: list(seed["west_relayed_groups"])}
VENDOR = seed["vendor_group"]
SEEDED = seed["seeded_groups"]
STREAM = {REGION: seed["stream_name"], WEST: seed["west_stream_name"]}
REGIONS = [REGION, WEST]

logs = {r: ck.client("logs", region_name=r) for r in REGIONS}
kin = {r: ck.client("kinesis", region_name=r) for r in REGIONS}


def svc_groups(region):
    out, tok = {}, None
    while True:
        kw = {"logGroupNamePrefix": "/svc/"}
        if tok:
            kw["nextToken"] = tok
        r = logs[region].describe_log_groups(**kw)
        for g in r["logGroups"]:
            out[g["logGroupName"]] = g
        tok = r.get("nextToken")
        if not tok:
            return out


present = {r: svc_groups(r) for r in REGIONS}
region_of = {}
for r in REGIONS:
    for g in present[r]:
        region_of[g] = r

for r in REGIONS:
    for g in RELAYED[r] + ([VENDOR] if r == REGION else []):
        ck.require(
            g in present[r],
            f"log group {g} no longer exists in {r}; the task states that every /svc/ log group "
            f"keeps the name it has now",
        )

# --- 1. functional: does every /svc/ log group actually reach its audit stream? ------------
MARK = secrets.token_hex(6)
PROBE = {r: f"/svc/relay-probe-{secrets.token_hex(6)}" for r in REGIONS}

LEFTOVER = {r: sorted(g for g in present[r] if g not in RELAYED[r] and g != VENDOR)
            for r in REGIONS}

for r in REGIONS:
    logs[r].create_log_group(logGroupName=PROBE[r])
    logs[r].create_log_stream(logGroupName=PROBE[r], logStreamName="application")
    region_of[PROBE[r]] = r
PROBE_CREATED = time.time()
time.sleep(20)

WATCHED = {r: RELAYED[r] + LEFTOVER[r] + [PROBE[r]] + ([VENDOR] if r == REGION else [])
           for r in REGIONS}

TEMPLATES = [
    "ERROR {} upstream call failed",
    "{}",
    "{} request completed in 12ms",
    '{{"event":"checkpoint","id":"{}"}}',
    "level=warn corr={} retries=2",
    "[{}] cache miss, falling through",
    "{}\tworker idle",
    "traceId {} span finished",
]
_rng = secrets.SystemRandom()
LINES = {}
for _r in REGIONS:
    for _g in WATCHED[_r]:
        LINES[_g] = [
            (f"line{i + 1}", secrets.token_hex(8), tmpl)
            for i, tmpl in enumerate(_rng.sample(TEMPLATES, 4))
        ]
TOKEN_OWNER = {tok: (g, kind) for g, rows in LINES.items() for kind, tok, _ in rows}
EXPECTED = {(g, kind)
            for r in REGIONS
            for g in RELAYED[r] + LEFTOVER[r] + [PROBE[r]]
            for kind, _, _ in LINES[g]}

iterators = {}
for r in REGIONS:
    try:
        shards = kin[r].describe_stream(StreamName=STREAM[r])["StreamDescription"]["Shards"]
    except Exception as exc:  # noqa: BLE001
        ck.fail(
            f"the audit stream {STREAM[r]} in {r} could not be described "
            f"({type(exc).__name__}: {exc}); the task states that the audit stream must not be "
            f"deleted or replaced"
        )
    iterators[r] = [
        kin[r].get_shard_iterator(StreamName=STREAM[r], ShardId=s["ShardId"],
                                  ShardIteratorType="LATEST")["ShardIterator"]
        for s in shards
    ]
time.sleep(5)

def write_lines(groups_by_region):
    """Write every group's four lines. Safe to repeat: the tokens stay the same, and a
    subscription forwards only what is ingested after it starts, so a group that begins
    relaying late still delivers a later copy."""
    now = int(time.time() * 1000)
    for r in REGIONS:
        for g in groups_by_region.get(r, []):
            try:
                logs[r].create_log_stream(logGroupName=g, logStreamName="application")
            except Exception:  # noqa: BLE001
                pass
            logs[r].put_log_events(
                logGroupName=g,
                logStreamName="application",
                logEvents=[
                    {"timestamp": now + i, "message": tmpl.format(tok)}
                    for i, (_kind, tok, tmpl) in enumerate(LINES[g])
                ],
            )


write_lines(WATCHED)
sent_at = time.time()

seen = set()
vendor_hits = []


def drain():
    for r in REGIONS:
        nxt = []
        for it in iterators[r]:
            try:
                rec_batch = kin[r].get_records(ShardIterator=it, Limit=500)
            except Exception:  # noqa: BLE001
                nxt.append(it)
                continue
            nxt.append(rec_batch["NextShardIterator"])
            for rec in rec_batch["Records"]:
                try:
                    d = json.loads(gzip.decompress(rec["Data"]).decode())
                except Exception:  # noqa: BLE001
                    continue
                if d.get("messageType") != "DATA_MESSAGE":
                    continue
                grp = d.get("logGroup")
                for ev in d.get("logEvents", []):
                    msg = ev.get("message", "")
                    for tok, (owner, kind) in TOKEN_OWNER.items():
                        if tok not in msg:
                            continue
                        seen.add((grp, kind))
                        if owner == VENDOR:
                            vendor_hits.append(
                                f"{msg[:60]!r} arrived in {STREAM[r]} ({r}) at "
                                f"{time.strftime('%H:%M:%SZ', time.gmtime())}, "
                                f"{int(time.time() - sent_at)}s after it was written"
                            )
        iterators[r] = nxt


def relay_state(groups):
    """What is actually configured right now, for whoever reads this failure."""
    out = []
    for r in REGIONS:
        try:
            pols = logs[r].describe_account_policies(
                policyType="SUBSCRIPTION_FILTER_POLICY")["accountPolicies"]
        except Exception as exc:  # noqa: BLE001
            pols = f"could not be read ({type(exc).__name__})"
        out.append(f"[{r}] account-level subscription filter policies: {pols if pols else 'none'}")
    for g in groups:
        r = region_of[g]
        cls = present[r].get(g, {}).get("logGroupClass", "created by the grader")
        try:
            fs = [
                {"name": f["filterName"], "pattern": f.get("filterPattern"),
                 "destination": f.get("destinationArn")}
                for f in logs[r].describe_subscription_filters(
                    logGroupName=g)["subscriptionFilters"]
            ]
        except Exception as exc:  # noqa: BLE001
            fs = f"could not be read ({type(exc).__name__}: {exc})"
        out.append(f"{g} ({r}): log class {cls}, own subscription filters {fs if fs else 'none'}")
    return " | ".join(out)


deadline = sent_at + 240
next_resend = sent_at + 50
while time.time() < deadline:
    time.sleep(6)
    drain()
    if EXPECTED <= seen:
        break
    if time.time() >= next_resend:
        still = {g for g, _ in EXPECTED - seen}
        write_lines({r: [g for g in WATCHED[r] if g in still or g == VENDOR]
                     for r in REGIONS})
        next_resend = time.time() + 50

missing = sorted(EXPECTED - seen)
if missing and not seen:
    ck.fail(
        f"nothing at all reached the audit streams within {int(time.time() - sent_at)}s: not one "
        f"line from any of the /svc/ log groups the grader wrote to, including the ones that "
        f"were already relaying when the work started. This is the relay path itself no longer "
        f"delivering, not one log group being missed. Both streams were read from LATEST on "
        f"every shard from before the lines were written. The state that produced this: "
        f"{relay_state([g for r in REGIONS for g in WATCHED[r]])}"
    )
if missing:
    per_group = {}
    for g, kind in missing:
        per_group.setdefault(g, []).append(kind)
    detail = "; ".join(
        f"{g} ({region_of[g]}): the {'/'.join(sorted(v))} line did not arrive"
        for g, v in sorted(per_group.items())
    )
    arrived = sorted({g for g, _ in seen if g != VENDOR}) or ["nothing"]
    ck.fail(
        f"log events written to the /svc/ log groups did not all reach the audit stream named "
        f"audit-relay-stream-* in their own region within {int(time.time() - sent_at)}s. "
        f"{detail}. Lines written at the same moment from {', '.join(arrived)} did arrive, so "
        f"the streams themselves were reading fine, and the same lines were written again "
        f"every 50s throughout, so a relay put in place late would still have caught one. The "
        f"state that produced this, read back at "
        f"grading time: {relay_state(sorted(per_group))}. The grader's own probe groups were "
        f"created after the work finished, {sent_at - PROBE_CREATED:.0f}s before their lines "
        f"were written, and nothing was configured on them by hand. Each group was sent four "
        f"lines carrying independent random tokens, in four message shapes drawn at random at "
        f"grading time out of eight, so no filter pattern written in advance can cover them and "
        f"only a relay that forwards everything delivers all four"
    )

grace = time.time() + 45
while time.time() < grace:
    time.sleep(6)
    drain()
if vendor_hits:
    ck.fail(
        f"events written to {VENDOR} reached the audit relay: {vendor_hits[0]}. The task states "
        f"that this log group's events must never reach the audit relay, while every other "
        f"/svc/ log group's must"
    )

# --- 2. the new groups had to be covered without anything on the groups themselves ---------
for r in REGIONS:
    pf = logs[r].describe_subscription_filters(logGroupName=PROBE[r])["subscriptionFilters"]
    ck.require(
        not pf,
        f"{PROBE[r]} was created by the grader in {r} after the work finished, and something "
        f"then configured the subscription filter(s) {[f['filterName'] for f in pf]!r} on the "
        f"group itself, targeting {[f.get('destinationArn') for f in pf]!r}. The task states "
        f"that a /svc/ log group created afterwards relays without being set up individually, "
        f"so coverage has to come from something that does not reach into each new group. "
        f"Delivery is graded separately and is not what failed here",
    )

# --- 3. restraints stated in the prompt ---------------------------------------------------
for r in REGIONS:
    for g in RELAYED[r] + ([VENDOR] if r == REGION else []):
        cur = present[r].get(g)
        ck.require(
            cur is not None,
            f"log group {g} no longer exists in {r}; the task states that every /svc/ log group "
            f"keeps the name it has now",
        )
        want = SEEDED[g].get("retentionInDays")
        got = cur.get("retentionInDays")
        ck.require(
            want == got,
            f"log group {g} in {r} is set to retain events for {got} days; it was seeded at "
            f"{want} days and the task states that every /svc/ log group keeps the retention "
            f"setting it has now",
        )

cur = present[REGION][VENDOR]
was = SEEDED[VENDOR]
for field in ("creationTime", "logGroupClass", "kmsKeyId", "dataProtectionStatus"):
    ck.require(
        cur.get(field) == was.get(field),
        f"{VENDOR} has {field}={cur.get(field)!r}, seeded as {was.get(field)!r}; the task "
        f"states that this log group is otherwise left exactly as it is",
    )
now_tags = logs[REGION].list_tags_for_resource(resourceArn=was["arn"]).get("tags", {})
ck.require(
    now_tags == was.get("tags", {}),
    f"{VENDOR} now carries the tags {now_tags!r}, seeded with {was.get('tags', {})!r}; the task "
    f"states that this log group is otherwise left exactly as it is",
)
vendor_filters = logs[REGION].describe_subscription_filters(
    logGroupName=VENDOR)["subscriptionFilters"]
ck.require(
    not vendor_filters,
    f"{VENDOR} now carries the subscription filter(s) "
    f"{[f['filterName'] for f in vendor_filters]!r}; it was seeded with none and the task "
    f"states that this log group is otherwise left exactly as it is",
)

for r, arn_key, created_key in ((REGION, "stream_arn", "stream_created"),
                                (WEST, "west_stream_arn", "west_stream_created")):
    sd = kin[r].describe_stream(StreamName=STREAM[r])["StreamDescription"]
    ck.require(
        sd["StreamARN"] == seed[arn_key],
        f"the audit stream {STREAM[r]} in {r} now has ARN {sd['StreamARN']}, seeded as "
        f"{seed[arn_key]}; the task states that it must not be deleted or replaced",
    )
    ck.require(
        sd["StreamCreationTimestamp"].isoformat() == seed[created_key],
        f"the audit stream {STREAM[r]} in {r} was created at "
        f"{sd['StreamCreationTimestamp'].isoformat()}, seeded at {seed[created_key]}, so it was "
        f"deleted and rebuilt under the same name; the task states that it must not be deleted "
        f"or replaced",
    )

iam = ck.client("iam")
try:
    role = iam.get_role(RoleName=seed["role_name"])["Role"]
except Exception as exc:  # noqa: BLE001
    ck.fail(
        f"the relay role {seed['role_name']} no longer exists ({type(exc).__name__}); the task "
        f"states that it must not be deleted or replaced"
    )
ck.require(
    role["RoleId"] == seed["role_id"],
    f"the relay role {seed['role_name']} now has RoleId {role['RoleId']}, seeded as "
    f"{seed['role_id']}, so it was deleted and rebuilt under the same name; the task states "
    f"that it must not be deleted or replaced",
)

ck.ok(
    f"every /svc/ log group in {REGION} and {WEST}, including the grader's fresh probe groups, "
    f"relayed all four lines to the audit stream in its own region, and {VENDOR} relayed none"
)
