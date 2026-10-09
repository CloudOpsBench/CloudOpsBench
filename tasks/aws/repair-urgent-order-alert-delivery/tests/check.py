"""Check that urgent order events reach the escalation queue as plain JSON.

Passes when the topic and queue still exist, a message published with
priority=urgent arrives on the queue without the SNS notification envelope, and
a message published with category=ComplianceAudit still arrives. Each probe
polls with retries because SNS to SQS delivery is not instantaneous.
"""
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
    """Drain the queue until `marker` is found, deleting unrelated messages."""
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


# A message using the producer's lowercase priority value must reach the queue.
urgent_marker = "urgent-%s" % uuid.uuid4().hex
publish(priority="urgent", marker=urgent_marker)
item = poll_for_marker(urgent_marker)
ck.require(item is not None,
           "a fresh urgent order event was published but never reached the "
           "escalation queue; something is still blocking delivery")

# The ComplianceAudit clause in the same FilterPolicy must still route.
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
