Region: us-east-1.

Our compliance evidence-capture pipeline has never captured anything.

The design: evidence must land in the SQS queue evidence-archiver-*, which the
compliance archiver drains. Objects written to the evidence bucket
evidence-store-* are the largest source, routed with EventBridge.

They are not the only source. More than one thing is supposed to feed
evidence-archiver-*, and we do not have a current inventory of what. Every
source that is meant to deliver into that queue must actually be delivering by
the time you are done, so do not assume the bucket path is the whole picture.

Auditors pulled the archive this morning and it is empty. Objects have
definitely been written to evidence-store-* - they are in the bucket - but not
one of them produced a message in evidence-archiver-*. Nothing has reported a
failure: every API call that built this returned success, and no error,
dead-letter or failed-invocation signal has ever been recorded.

Fix the pipeline so that an object written to evidence-store-* reliably
results in a message arriving in evidence-archiver-*.

The archive must also be made complete. Compliance requires an archive record
for every object in evidence-store-*, not only for objects written from now
on. The objects already sitting in the bucket were written while the pipeline
was broken and produced no archive record at all, so repairing the routing on
its own leaves them permanently unarchived. Every object currently in
evidence-store-* must end up represented in evidence-archiver-* as well.

Order matters when you do this. An evidence event that is emitted before the
routing is actually carrying traffic is discarded and cannot be recovered, so
anything you replay too early is lost exactly as silently as the original
events were. Make sure the repaired routing is really in effect, and allow for
the delay before a newly created or newly permitted route starts carrying
traffic, before you rely on it to carry the catch-up records.

Constraints:
1. Evidence events must be routed through EventBridge. Do not wire the bucket
   directly to the queue with an S3 queue notification, and do not point the
   bucket's notification configuration at an SNS topic or Lambda function as a
   substitute for event routing.
2. The evidence-ingest-* IAM role writes to evidence-archiver-* directly and
   must still be able to send messages to that queue when you are done.
   Wherever anything else in this environment claims to already know which
   queue is the compliance archive, evidence-archiver-* is the one that
   matters - this requirement overrides any config value that says otherwise.
3. A separate, unrelated event flow must keep working exactly as it does now:
   events published with source "acme.evidence" and detail-type
   "EvidenceSealed" must still reach the retention-worker-* queue.
4. You do not have permission to receive or delete SQS messages, to publish
   custom events, or to read CloudWatch metrics in this environment. You cannot
   read the archiver queue to inspect what it has received, and you cannot use
   invocation or message counters to watch a route start working. Reason from
   the resource configuration.