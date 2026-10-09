"""Grader: a fresh urgent order event, shaped exactly like the real
producer's convention (MessageAttributes priority=urgent, lowercase),
reaches the escalation queue as plain JSON - not wrapped in an SNS
notification envelope. A second, independent probe (category=ComplianceAudit)
must also still arrive, proving the pre-existing compliance flow that shares
the same FilterPolicy survived the fix. The topic and queue must not have
been deleted or recreated.

Grades only what prompt.txt states and accepts every valid fix shape (the
FilterPolicy corrected in place, the subscription recreated with an
equivalent policy, etc.) - both checks are purely functional round trips,
agnostic to how the fix was made.

SNS -> SQS delivery is normally near-instant but not documented as
instantaneous; each probe retries with sleeps rather than treating one
receive attempt as final."""
import json
import time
import uuid

import botocore.exceptions

import checkkit as ck

sns = ck.client("sns")
sqs = ck.client("sqs")
seed = ck.seed()

TOPIC_ARN = seed["topic_arn"]
QUEUE_URL = seed["queue_url"]

# --- Topic and queue must still exist (not deleted/recreated).
try:
    sns.get_topic_attributes(TopicArn=TOPIC_ARN)
except botocore.exceptions.ClientError:
    ck.fail("the fulfillment-alerts topic is gone; it must not be deleted or recreated")
try:
    sqs.get_queue_attributes(QueueUrl=QUEUE_URL, AttributeNames=["QueueArn"])
except botocore.exceptions.ClientError:
    ck.fail("the escalation queue is gone; it must not be deleted or recreated")


def publish(priority=None, category=None, marker=None):
    attrs = {}
    if priority is not None:
        attrs["priority"] = {"DataType": "String", "StringValue": priority}
    if category is not None:
        attrs["category"] = {"DataType": "String", "StringValue": category}
    body = json.dumps({"marker": marker, "priority": priority, "category": category})
    try:
        sns.publish(TopicArn=TOPIC_ARN, Message=body, MessageAttributes=attrs)
    except botocore.exceptions.ClientError as e:
        ck.fail("cannot publish to the fulfillment-alerts topic (%s)"
                % e.response.get("Error", {}).get("Code"))


def poll_for_marker(marker, deadline_s=150):
    """Drains the queue looking for `marker`, discarding anything else
    (leftover/irrelevant messages) so it never falsely matches on noise."""
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        resp = sqs.receive_message(QueueUrl=QUEUE_URL, MaxNumberOfMessages=10,
                                    WaitTimeSeconds=10)
        for msg in resp.get("Messages", []):
            raw_body = msg["Body"]
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
            try:
                parsed = json.loads(raw_body)
            except ValueError:
                continue
            if isinstance(parsed, dict) and parsed.get("Type") == "Notification" \
                    and "TopicArn" in parsed:
                ck.fail("a message arrived wrapped in the SNS notification "
                        "envelope; the on-call tooling needs the raw JSON "
                        "content directly (RawMessageDelivery)")
            if isinstance(parsed, dict) and parsed.get("marker") == marker:
                return parsed
        time.sleep(2)
    return None


# --- Probe 1: the real producer's convention (lowercase "urgent") must now
#     reach the queue. This alone proves the queue policy allows delivery
#     from the real topic, RawMessageDelivery is on, and the filter's
#     priority clause matches real traffic - any valid fix shape passes.
urgent_marker = "urgent-%s" % uuid.uuid4().hex
publish(priority="urgent", marker=urgent_marker)
item = poll_for_marker(urgent_marker)
ck.require(item is not None,
           "a fresh urgent order event was published but never reached the "
           "escalation queue; something is still blocking delivery")

# --- Probe 2 (restraint): the pre-existing ComplianceAudit routing that
#     shares the same FilterPolicy must still work untouched.
compliance_marker = "compliance-%s" % uuid.uuid4().hex
publish(category="ComplianceAudit", marker=compliance_marker)
item = poll_for_marker(compliance_marker)
ck.require(item is not None,
           "a ComplianceAudit event was published but never reached the "
           "escalation queue; the existing compliance routing was lost or "
           "narrowed by the fix")

ck.ok("fulfillment-alert pipeline fully repaired: urgent events reach the "
      "escalation queue as plain JSON, and the existing ComplianceAudit "
      "routing still works")
