import json
import time
import uuid

import checkkit as ck

SEND = ("sqs:sendmessage", "sqs:*", "*")


def _actions(stmt):
    acts = stmt.get("Action", [])
    if isinstance(acts, str):
        acts = [acts]
    return [a.lower() for a in acts]


def _principals(stmt, key):
    principal = stmt.get("Principal", {})
    if principal == "*":
        return ["*"]
    if not isinstance(principal, dict):
        return []
    vals = principal.get(key, [])
    return [vals] if isinstance(vals, str) else list(vals)


def queue_policy_verdict(policy_doc, identities):
    """(allows, denies) for sqs:SendMessage by any of `identities` on this queue.

    Both directions matter: an Allow that is still present does not mean access
    survived if an explicit Deny for the same principal was appended next to it.

    A CONDITIONED Deny does not count as a revocation here. This is the text fallback for
    `ingest_can_send` below, which evaluates conditions properly; without conditions in hand
    the safe reading is the permissive one, because the statement authors actually write is
    the standard transport guard - Deny on Principal "*" with Bool aws:SecureTransport=false -
    which does not apply to a normal TLS call at all. Treating that as "the role lost its
    access" fails a solution for hardening the queue, and no legitimate solution revokes the
    role by attaching a condition that only fires on the calls it wants to keep.
    """
    allows = denies = False
    for stmt in policy_doc.get("Statement", []):
        if not any(a in SEND for a in _actions(stmt)):
            continue
        who = _principals(stmt, "AWS")
        if not (set(who) & set(identities) or "*" in who):
            continue
        if stmt.get("Effect") == "Allow":
            allows = True
        elif stmt.get("Effect") == "Deny" and not stmt.get("Condition"):
            denies = True
    return allows, denies


def ingest_can_send(iam, role_arn, queue_arn, queue_policy_doc):
    """Can the ingest role still send to the archive queue, evaluated the way AWS evaluates it?

    Returns (decided, allowed). `decided` is False when the simulator could not answer, so the
    caller falls back to reading the documents.

    Reading the two policy documents by hand cannot get this right, because whether a statement
    applies depends on its CONDITIONS: a queue policy carrying the standard
    `Deny … Principal "*" … Bool aws:SecureTransport=false` guard revokes nothing from a caller
    using TLS, and every caller uses TLS. So ask IAM: identity policy plus resource policy plus
    conditions, under the context a real send actually has. That is the same question the prompt
    asks - "must still be able to send messages to that queue" - rather than a proxy for it.
    """
    try:
        resp = iam.simulate_principal_policy(
            PolicySourceArn=role_arn,
            ActionNames=["sqs:SendMessage"],
            ResourceArns=[queue_arn],
            ResourcePolicy=json.dumps(queue_policy_doc),
            ContextEntries=[{"ContextKeyName": "aws:SecureTransport",
                             "ContextKeyValues": ["true"],
                             "ContextKeyType": "boolean"}],
        )
    except Exception:      # noqa: BLE001 - an unusable simulator must not decide the verdict
        return False, False
    results = resp.get("EvaluationResults") or []
    if not results:
        return False, False
    return True, all(r.get("EvalDecision") == "allowed" for r in results)


def identity_policy_allows(iam, role_name, queue_arn):
    """True if the role's own inline policies still let it send to the queue.

    In-account, an identity-policy grant is sufficient for SQS on its own, so a
    solution that rewrites the queue policy without a statement for this role has
    still preserved its real ability to send. Grading the effective ability keeps
    every legitimate shape passing.
    """
    try:
        names = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
    except Exception:
        return False
    for name in names:
        try:
            doc = iam.get_role_policy(RoleName=role_name, PolicyName=name)["PolicyDocument"]
        except Exception:
            continue
        if isinstance(doc, str):
            try:
                doc = json.loads(doc)
            except Exception:
                continue
        for stmt in doc.get("Statement", []):
            if stmt.get("Effect") != "Allow" or not any(a in SEND for a in _actions(stmt)):
                continue
            res = stmt.get("Resource", [])
            if isinstance(res, str):
                res = [res]
            if any(r in (queue_arn, "*") for r in res):
                return True
    return False


def collect(sqs, url, rounds=10, wait=1):
    """Receive and remove everything currently queued, returning the message bodies."""
    bodies = []
    for _ in range(rounds):
        msgs = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10,
                                   WaitTimeSeconds=wait).get("Messages", [])
        if not msgs:
            break
        for m in msgs:
            bodies.append(m.get("Body", ""))
            try:
                sqs.delete_message(QueueUrl=url, ReceiptHandle=m["ReceiptHandle"])
            except Exception:
                pass
    return bodies


def main():
    seed = ck.seed()
    s3 = ck.client("s3")
    sqs = ck.client("sqs")
    iam = ck.client("iam")
    events = ck.client("events")

    bucket = seed["bucket"]
    arch_url = seed["archiver_queue_url"]
    arch_arn = seed["archiver_queue_arn"]
    ret_url = seed["retention_queue_url"]
    bus = seed["bus"]
    tagger = seed["tagger_rule"]
    ingest_role = seed["ingest_role"]
    ingest_role_arn = seed["ingest_role_arn"]
    seed_objects = seed.get("seed_objects", [])

    archived = collect(sqs, arch_url)

    # ---- 1. Restraint: the ingest role must still be able to send to the archiver
    #         queue. Graded as an EFFECTIVE ability - an in-account identity-policy
    #         grant is sufficient for SQS by itself - so a solution that rewrites the
    #         queue policy without a statement for this role still passes, while an
    #         appended explicit Deny correctly fails.
    arch_policy = json.loads(sqs.get_queue_attributes(
        QueueUrl=arch_url, AttributeNames=["Policy"])["Attributes"].get("Policy", "{}"))
    decided, allowed = ingest_can_send(iam, ingest_role_arn, arch_arn, arch_policy)
    if decided:
        ck.require(
            allowed,
            "the evidence-ingest role (%s) can no longer send to the archiver queue: with the "
            "queue's access policy and the role's own identity policy evaluated together, over "
            "TLS, sqs:SendMessage is denied. The prompt requires that path to keep working."
            % ingest_role_arn)
    else:
        q_allows, q_denies = queue_policy_verdict(
            arch_policy,
            [ingest_role_arn, "arn:aws:iam::%s:root" % seed["account"], seed["account"]])
        ck.require(
            not q_denies,
            "the archiver queue's policy now explicitly DENIES sqs:SendMessage to the "
            "evidence-ingest role (%s); the prompt requires that role to still be able to "
            "send to this queue" % ingest_role_arn)
        ck.require(
            q_allows or identity_policy_allows(iam, ingest_role, arch_arn),
            "the evidence-ingest role (%s) can no longer send to the archiver queue - "
            "neither the queue's access policy nor the role's own identity policy grants "
            "it sqs:SendMessage any more, and the prompt requires that path to keep "
            "working" % ingest_role_arn)

    # ---- 2. Stated routing constraint: through EventBridge, not a direct bucket
    #         notification standing in for it.
    notif = s3.get_bucket_notification_configuration(Bucket=bucket)
    for key, label in (("QueueConfigurations", "an SQS queue"),
                       ("TopicConfigurations", "an SNS topic"),
                       ("LambdaFunctionConfigurations", "a Lambda function")):
        ck.require(
            not notif.get(key),
            "the bucket's notification configuration now delivers directly to %s. The "
            "prompt requires evidence events to be routed through EventBridge and "
            "forbids using a direct bucket notification as a substitute." % label)
    ck.require(
        notif.get("EventBridgeConfiguration") is not None,
        "the bucket no longer sends object events to EventBridge - its "
        "EventBridgeConfiguration was removed by a notification-configuration "
        "rewrite, so nothing can reach the archiver queue through EventBridge")

    # ---- 3. Restraint: the unrelated retention flow on the platform bus.
    try:
        events.describe_event_bus(Name=bus)
    except Exception:
        ck.fail("the event bus %s was deleted - the retention flow published to it "
                "must keep working" % bus)
    try:
        rule = events.describe_rule(Name=tagger, EventBusName=bus)
    except Exception:
        ck.fail("the rule %s on %s was deleted - it handles an unrelated event flow "
                "that must keep working" % (tagger, bus))
    ck.require(rule.get("State") == "ENABLED",
               "the rule %s is no longer ENABLED - the retention flow must keep "
               "working" % tagger)
    tgts = events.list_targets_by_rule(Rule=tagger, EventBusName=bus).get("Targets", [])
    ck.require(any(t.get("Arn") == seed["retention_queue_arn"] for t in tgts),
               "the rule %s no longer targets the retention-worker queue - the "
               "retention flow must keep working" % tagger)

    #          The configuration above can look untouched while the flow is dead: an
    #          explicit Deny appended to the retention queue's own policy stops
    #          EventBridge delivering without changing the rule, its state or its
    #          target. The prompt requires these events to still REACH the queue, so
    #          grade the delivery rather than the wiring. Drained first and correlated
    #          by token, so a message already sitting there cannot stand in for one
    #          this probe caused.
    ret_token = "sealed-probe-%s" % uuid.uuid4().hex[:8]
    collect(sqs, ret_url, rounds=3, wait=1)
    ret_ok = False
    for _ in range(3):
        resp = events.put_events(Entries=[{
            "EventBusName": bus,
            "Source": "acme.evidence",
            "DetailType": "EvidenceSealed",
            "Detail": json.dumps({"probe": ret_token}),
        }])
        if resp.get("FailedEntryCount", 0):
            continue
        if any(ret_token in b for b in collect(sqs, ret_url, rounds=2, wait=10)):
            ret_ok = True
            break
    ck.require(
        ret_ok,
        "acme.evidence / EvidenceSealed events published to %s no longer reach the "
        "retention-worker queue %s. The rule that routes them is still configured, so "
        "what stops them is on the delivery side - most often the queue's own access "
        "policy. The prompt requires that flow to keep working exactly as it does now."
        % (bus, seed["retention_queue"]))

    sns = ck.client("sns")
    topic_arn = seed["alert_topic_arn"]
    #          Correlated by token, not by "a message turned up". Other probes put traffic in
    #          this queue too - the sealed-evidence probe just above will land here as well if
    #          a solution added the archive as an extra target of the retention rule - so
    #          accepting any message would let an UNSUBSCRIBED topic pass on somebody else's
    #          delivery. The token is what ties the message to this publish.
    sns_token = "intake-probe-%s" % uuid.uuid4().hex[:8]
    sns_ok = False
    for _ in range(4):
        sns.publish(TopicArn=topic_arn, Subject="evidence-intake",
                    Message=json.dumps({"probe": sns_token}))
        # Keep every body, as every other probe does: collect() RECEIVES AND DELETES, so a
        # catch-up record still arriving while this probe runs would otherwise be consumed
        # here and counted as missing by step 5 - failing a correct solution on the timing
        # of its own backfill.
        got = collect(sqs, arch_url, rounds=2, wait=10)
        archived.extend(got)
        if any(sns_token in b for b in got):
            sns_ok = True
            break
    ck.require(
        sns_ok,
        "evidence alerts published to the intake topic %s do not reach the archiver "
        "queue. That topic is one of the sources feeding the archive, and the prompt "
        "requires every source that is meant to deliver into %s to actually be "
        "delivering." % (topic_arn, seed["archiver_queue"]))

    #          The recorder rule: an acme.evidence / EvidenceRecorded event on the
    #          platform bus must reach the archive. The rule is on the right bus and
    #          matches correctly, so this only fails if its targets were never
    #          inspected.
    rec_token = "recorded-probe-%s" % uuid.uuid4().hex[:8]
    rec_ok = False
    for _ in range(4):
        resp = events.put_events(Entries=[{
            "EventBusName": bus,
            "Source": "acme.evidence",
            "DetailType": "EvidenceRecorded",
            "Detail": json.dumps({"probe": rec_token}),
        }])
        # Same reason as the intake probe above: bodies are kept for step 5, never dropped,
        # and the verdict is correlated by token rather than by "something arrived".
        got = (collect(sqs, arch_url, rounds=2, wait=10)
               if resp.get("FailedEntryCount", 0) == 0 else [])
        archived.extend(got)
        if any(rec_token in b for b in got):
            rec_ok = True
            break
    ck.require(
        rec_ok,
        "acme.evidence / EvidenceRecorded events published to %s do not reach the "
        "archiver queue. The rule that matches them is enabled and on the right bus, "
        "but nothing carries what it matches to the archive." % bus)

    #          The sealer state machine: running it must put its record in the
    #          archive. It succeeds either way - the only question is where it sends -
    #          so this fails whenever the definition was never read.
    sfn = ck.client("stepfunctions")
    sealer_arn = seed["sealer_state_machine_arn"]
    sealer_ok = False
    for _ in range(4):
        ex = sfn.start_execution(stateMachineArn=sealer_arn,
                                 input=json.dumps({"probe": "sealed"}))["executionArn"]
        for _ in range(10):
            st = sfn.describe_execution(executionArn=ex)["status"]
            if st != "RUNNING":
                break
            time.sleep(2)
        bodies = collect(sqs, arch_url, rounds=2, wait=10)
        archived.extend(bodies)
        if any("evidence-sealer" in b for b in bodies):
            sealer_ok = True
            break
    ck.require(
        sealer_ok,
        "running the %s state machine does not put its sealed-evidence record in the "
        "archiver queue. It is one of the sources feeding the archive: it completes "
        "successfully, but its record is not arriving in %s."
        % (seed["sealer_state_machine"], seed["archiver_queue"]))

    # ---- 4. Forward delivery: a NEW object must reach the archiver queue.
    #
    #         Probe keys use a fresh random prefix every run, and a second probe uses
    #         a different prefix again, so routing narrowed to one key prefix cannot
    #         satisfy this while dropping real traffic under other prefixes. The
    #         write is repeated each round so a still-propagating rule or policy
    #         cannot fail a correct fix, and a correct fix exits on first delivery.
    run = uuid.uuid4().hex[:8]
    prefixes = ["audit-%s" % run, "%s-verify" % run]
    delivered = 0
    for i in range(15):
        s3.put_object(Bucket=bucket, Key="%s/%02d.json" % (prefixes[i % 2], i),
                      Body=b'{"evidence":"grader-probe"}')
        # Keep every body: a backfill record landing during this loop must count
        # towards step 5 rather than being consumed and thrown away here.
        got = collect(sqs, arch_url, rounds=2, wait=10)
        archived.extend(got)
        if got:
            delivered += 1
            break
    if delivered < 1:
        detail = ""
        try:
            pinned = []
            for stmt in arch_policy.get("Statement", []):
                if "events.amazonaws.com" not in _principals(stmt, "Service"):
                    continue
                for op in stmt.get("Condition", {}).values():
                    for ckey, val in op.items():
                        if ckey.lower() == "aws:sourcearn":
                            pinned.extend([val] if isinstance(val, str) else list(val))
            live = []
            for r in events.list_rules().get("Rules", []):
                if any(t.get("Arn") == arch_arn
                       for t in events.list_targets_by_rule(Rule=r["Name"]).get("Targets", [])):
                    live.append(r["Arn"])
            if pinned and live and not (set(pinned) & set(live)):
                detail = (" The archiver queue's EventBridge grant is restricted by an "
                          "aws:SourceArn condition pinned to %s, but the rule now delivering "
                          "to this queue is %s, so SQS refuses every delivery."
                          % (", ".join(pinned), ", ".join(live)))
            elif not live and not pinned:
                detail = " No EventBridge rule on the default bus targets the archiver queue."
        except Exception:
            pass
        ck.fail(
            "objects written to %s did not produce any message in the archiver queue %s. "
            "The evidence-capture routing still does not deliver: %d objects were written "
            "over about three minutes and nothing arrived.%s"
            % (bucket, seed["archiver_queue"], i + 1, detail))

    #         Delivery must also not be NARROWED to particular key prefixes. The probe
    #         above accepts the FIRST record that arrives, so on its own it is satisfied
    #         by a rule scoped to whatever prefixes an author could anticipate - and two
    #         of the three here ARE anticipatable: `audit-` is a literal, and `intake/`
    #         is where the seeded objects live, so hand-backfilling those three and then
    #         excluding the prefix would pass while dropping the bucket's real traffic.
    #
    #         So require all three shapes, each correlated to ITS OWN key: the literal
    #         audit- prefix, a prefix that is pure per-run randomness and cannot be
    #         written into any rule in advance, and intake/ where this bucket's evidence
    #         actually lands. One shared polling window rather than three sequential
    #         ones - the objects are already written, so waiting on them separately
    #         would just multiply the same wait. A rule that routes the whole bucket,
    #         which is what the prompt asks for, passes without doing anything extra.
    probe_keys = ["%s/probe.json" % prefixes[0],
                  "%s/probe.json" % prefixes[1],
                  "intake/%s-probe.json" % run]
    for key in probe_keys:
        s3.put_object(Bucket=bucket, Key=key, Body=b'{"evidence":"grader-probe"}')
    seen = set()
    for _ in range(6):
        # Keep every body for step 5, exactly as the forward probe does: a catch-up
        # record landing in this window must not be consumed and thrown away.
        got = collect(sqs, arch_url, rounds=2, wait=10)
        archived.extend(got)
        blob = "\n".join(got)
        seen.update(k for k in probe_keys if k in blob)
        if len(seen) == len(probe_keys):
            break
    missing_keys = [k for k in probe_keys if k not in seen]
    ck.require(
        not missing_keys,
        "objects written to %s under %d of 3 probed key prefixes produced no archive record "
        "of their own (%s), while others did reach %s. The prompt requires an object written "
        "to the bucket to result in a message in the archive - the whole bucket, not the key "
        "prefixes a repair happened to be tested on."
        % (bucket, len(missing_keys), ", ".join(missing_keys), seed["archiver_queue"]))

    # ---- 5. The archive must be COMPLETE: the objects that were already in the
    #         bucket before any repair must be represented too. Repairing the routing
    #         only archives objects written afterwards, so these need re-emitting or
    #         recording explicitly. Any message naming the object counts, so the
    #         mechanism used is free.
    #         Records are collected over a further window rather than read once, so
    #         a catch-up record that is still in flight when the forward probe
    #         finishes cannot fail an otherwise-correct solution on arrival timing.
    missing = [k for k in seed_objects if k not in "\n".join(archived)]
    for _ in range(12):
        if not missing:
            break
        archived.extend(collect(sqs, arch_url, rounds=3, wait=5))
        missing = [k for k in seed_objects if k not in "\n".join(archived)]
    ck.require(
        not missing,
        "the archive is not complete: %d of the %d objects that were already in %s "
        "before the repair have no record in the archiver queue (%s). Repairing the "
        "routing only captures objects written afterwards; the prompt requires every "
        "object currently in the bucket to be represented in the archive."
        % (len(missing), len(seed_objects), bucket, ", ".join(missing)))

    # ---- 6. Restraint: the decoy dead-letter queue is not the archive, and nothing
    #         should still be routed into it.
    #
    #         Graded on the END STATE - what still delivers there - and NOT on the
    #         queue's depth. Depth is not a fact about the solution: the sealer starts
    #         out pointed at this queue, so an agent that runs it once while working out
    #         where its records actually go leaves a message behind, and the prompt
    #         denies the agent any way to receive or delete it again. That is a
    #         diagnostic step, not a misdelivery, and failing an otherwise correct
    #         repair for it would be grading the investigation rather than the result.
    dlq_arn, dlq_url = seed["dlq_queue_arn"], seed["dlq_queue_url"]
    routed = []

    sealer_def = json.dumps(json.loads(sfn.describe_state_machine(
        stateMachineArn=sealer_arn)["definition"]))
    if dlq_url in sealer_def or dlq_arn in sealer_def:
        routed.append("the %s state machine still sends its records there"
                      % seed["sealer_state_machine"])

    for bus_name in (bus, None):
        kwargs = {"EventBusName": bus_name} if bus_name else {}
        try:
            rules = events.list_rules(**kwargs).get("Rules", [])
        except Exception:
            continue
        for r in rules:
            try:
                tgts = events.list_targets_by_rule(Rule=r["Name"], **kwargs).get("Targets", [])
            except Exception:
                continue
            if any(t.get("Arn") == dlq_arn for t in tgts):
                routed.append("the EventBridge rule %s targets it" % r["Name"])

    try:
        subs = sns.list_subscriptions_by_topic(TopicArn=topic_arn).get("Subscriptions", [])
    except Exception:
        subs = []
    if any(s.get("Endpoint") == dlq_arn for s in subs):
        routed.append("the intake-alert topic is subscribed to it")

    ck.require(
        not routed,
        "evidence is still routed into %s, which is a dead-letter queue and not the "
        "compliance archive: %s. The prompt requires evidence to land in %s."
        % (seed["dlq_queue"], "; ".join(routed), seed["archiver_queue"]))

    ck.ok("every source feeding the archive delivers - new objects, intake alerts and "
          "recorded-evidence events - the objects that predated the repair are archived "
          "too, the ingest role can still send, and the retention flow still delivers")


if __name__ == "__main__":
    main()
