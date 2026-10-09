Author self-review.

The prompt states every graded criterion. Evidence must land in
evidence-archiver-*. More than one source is meant to feed that queue, there is
no current inventory of what they are, and every source that is supposed to
deliver into it must actually be delivering when the work is done - the prompt
says this explicitly rather than leaving it implied. It states the one routing
constraint for the bucket path (through EventBridge, not a direct bucket
notification substituting for it), that the evidence-ingest-* role must keep
its ability to send, that requirement overrides any config value that claims
otherwise, that the unrelated acme.evidence retention flow must keep working,
and the ordering hazard in any historical replay: an event emitted before a
route is actually carrying traffic is discarded and cannot be recovered, so the
repaired route needs to be verified live before it is relied on to carry
catch-up records.

None of the sources or their locations are named beyond what the prompt already
states. That is deliberate: every one of them is reachable with ordinary
list/describe calls once you go looking, and finding what feeds the queue is
the graded work, not something to be handed over in the brief.

I want to be direct about where the difficulty actually sits, because it is not
one clever fault:
- an EventBridge rule stranded on a custom bus, whose events can never arrive,
- a queue-policy condition that the obvious re-homing fix silently invalidates,
- an SNS topic that is supposed to feed the queue and is neither subscribed to
  it nor granted access to it,
- a second EventBridge rule that matches correctly and has no target at all,
- a Step Functions state machine whose AWS-SDK integration succeeds every time
  and sends its output to the wrong queue, traceable to a stale SSM parameter
  that looks authoritative and is not,
- historical objects that predate the repair and need to be replayed, correctly
  ordered against the route becoming live.
No single one of these is exotic; the difficulty is that there are several,
spread across five services, with no inventory handed over and no signal that
distinguishes "found everything" from "found some of it."

The agent cannot receive or delete queue messages, publish events or
notifications, or read CloudWatch metrics - disclosed verbatim in the prompt.
That closes every channel I found being used in earlier rounds to confirm a fix
worked before moving on, including counters and invocation metrics. The
diagnosis has to be done from configuration, and the repaired result has to be
trusted rather than watched.

The grader checks nothing beyond what is stated. It verifies every source
functionally - a written object, a published alert, a matched custom event, a
state-machine execution - actually produces a record in the archive, that the
historical objects are represented too, that the ingest role's access survived,
that the unrelated retention flow still works, and that nothing was
misdelivered into the decoy dead-letter queue. Grading is outcome-based: any
routing shape that achieves the stated result passes, not just the reference
shape. Functional checks retry across a window generous enough that a
still-propagating fix cannot fail on timing, and exit as soon as a correct
delivery is observed rather than waiting the window out.

The gate was verified end to end on live AWS before submission: the seeded
state fails on the first thing it should fail on, the reference solution
passes, and fixes that repair some sources while leaving others incomplete -
including the specific combinations most likely to be attempted next - still
fail on the parts left undone.

Docking 0.08 as a pre-rollout margin. Will re-verify against the actual
trajectories.

Score: 0.92


--------------------------------------------------------------------------------
Harbor conversion (v2). Same task: prompt.txt, solution and the whole seeded
environment are unchanged except where noted below. Two fairness findings from the
v1 judges are addressed; neither touches the prompt.

1. setup.sh — the intake-alert SNS topic now carries a DisplayName and the tags
   Component=compliance-evidence / DeliversTo=<archiver queue>. BOTH fairness judges
   independently flagged that this topic is hard-required by the grader while nothing
   in the environment linked it to the archive: "the only clue is the topic name, so a
   reasonable agent could treat it as an ops-alert topic and fail". Every other source
   states its purpose on the resource (the rules carry descriptions, the queues carry
   policies); this one carried nothing. It is still UNSUBSCRIBED and UNGRANTED, so the
   work of wiring it up is untouched — only the guess about whether it belongs is.

2. tests/check.py — two false-pass routes closed, both named by gpt-5.6-terra:
   * The retention flow was graded on CONFIGURATION only, so appending an explicit
     Deny to the retention queue's policy broke delivery while the rule, its state
     and its target all still looked right. Now an EvidenceSealed event is published
     and its arrival in the retention queue is verified, correlated by token.
   * The forward probe broke on its first delivery under a random prefix, so a
     solution could hand-backfill the three seeded intake/ objects and then narrow
     the capture rule to exclude intake/ keys. Now an object written under intake/
     must produce its own record, correlated by key.
   Both make the grader stricter and neither can fail a solution that routes the
   bucket as the prompt asks; the reference solution passes both unchanged.

3. tests/check.py (v3) — the dead-letter-queue restraint is graded on the END STATE
   instead of on queue depth. gpt-5.6-terra, re-judging v2 at 0.93, flagged the depth
   assertion as the one remaining way to fail a correct solution: the sealer starts out
   pointed at that queue, so an agent that RUNS it once to work out where its records go
   leaves a message behind, and the prompt denies the agent any way to receive or delete
   it. The check now asks what still delivers there - the sealer's definition, any
   EventBridge rule on either bus, an SNS subscription - which is the thing the restraint
   was ever about, and cannot be tripped by a diagnostic action taken before the repair.

4. tests/check.py + solution/solve.sh (v4) — the two findings Opus 4.8 raised against v3,
   both of which could fail a CORRECT solution rather than let a wrong one through:
   * The intake-topic and recorder probes called collect() on the archive queue and threw
     the bodies away. collect() receives AND DELETES, so a catch-up record still arriving
     during those windows was destroyed, and step 5 then reported the archive incomplete -
     silently failing a solution for the timing of its own backfill. Every probe now
     extends `archived`, which is what the forward probe already did and said it did.
   * The reference discovered the archive with the prefix `evidence-archiver-`, which also
     matches the decoy `evidence-archiver-dlq-*`; list-queues promises no ordering, so
     QueueUrls[0] could have handed the golden arm the dead-letter queue and sent the whole
     repair into it. The filter now excludes the DLQ by name.
   Neither touches what the agent has to do; both are the grader and the reference being
   correct about their own contract.

5. tests/check.py (v5) — the remaining grader findings from both judges, closed together.
   * The intake-alert and recorder probes accepted ANY message arriving in the archive as
     proof that their source was delivering. That was already loose, and v2's retention
     probe made it reachable: a solution that added the archive as an extra target of the
     retention rule put a message in the queue right before the intake probe ran, so an
     UNSUBSCRIBED topic could pass on somebody else's delivery. Both probes now publish a
     unique token and require it in the received body. (gpt-5.6-terra, v4 — a regression
     this conversion introduced, not a pre-existing defect.)
   * The ingest-role restraint read the policy documents and treated ANY wildcard Deny as a
     revocation, ignoring conditions - so the standard hardening statement, Deny on
     Principal "*" with Bool aws:SecureTransport=false, failed a solution whose ingest role
     had lost nothing at all. The check now asks IAM to evaluate the effective permission
     (identity policy + resource policy + conditions, under TLS) and falls back to the text
     read only if the simulator cannot answer - and that fallback no longer counts a
     conditioned Deny. (gpt-5.6-terra, v4.)
   * Forward delivery is now verified under THREE key shapes, each correlated to its own
     key: the literal `audit-` prefix, a prefix that is pure per-run randomness and cannot
     be written into a rule in advance, and `intake/`. The single-delivery probe could be
     satisfied by a capture rule scoped to the two anticipatable prefixes after
     hand-backfilling the seeded objects. One shared polling window, so this costs about
     20 seconds more than the single-prefix probe it replaces. (gpt-5.6-terra, v3.)

   Still open and deliberately not fixed: Opus 4.8 on v4 asks for a hint that a direct-send
   source targets the wrong queue, and for the prompt's sealer/SSM phrasing to be tightened.
   Both are prompt edits, and the prompt is being held byte-identical to v1.
