Region: us-east-1.

Our fulfillment-alerts SNS topic (fulfillment-alerts-topic-*) is supposed to
forward urgent order events to the on-call escalation queue
(oncall-escalation-queue-*) so the on-call engineer's tooling can react in
real time. Right now nothing new is showing up in that queue for urgent
orders. No errors, bounces, or subscription failures have fired anywhere -
the topic and the subscription both look healthy.

Find and fix every reason urgent order events are not reaching the
escalation queue, then confirm a fresh urgent event actually arrives there.

Constraints:
1. The on-call tooling reads the queue's messages as plain JSON - it does
   not understand SNS's notification envelope format. Whatever you fix must
   deliver the event content directly, not wrapped in extra SNS metadata.
2. The same queue also receives an unrelated category of message today
   (compliance audit records) that already arrives correctly and must keep
   arriving. Nothing about that existing flow may be lost or narrowed by
   your fix.
3. Do not delete or recreate the topic or the queue. Do not touch resources
   unrelated to this pipeline.