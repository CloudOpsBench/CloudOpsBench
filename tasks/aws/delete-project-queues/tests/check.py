"""Grader: exit 0 = PASS.

Every vera2 queue must be gone. A queue cleanup that only runs `sqs list-queues` misses AWS Elemental
MediaConvert queues: a MediaConvert queue is a queue too, but it is enumerated by `mediaconvert list-queues`
(against the account-specific endpoint), never by `sqs list-queues`. The MediaConvert check is the golden-
critical, strongly-consistent gate and is evaluated first. SQS `list-queues` is eventually consistent on
delete, so a correctly-deleted decoy can linger briefly; the SQS positive-control is therefore polled with a
bounded wait (only on the otherwise-passing path).
"""
import time
import boto3
import checkkit as ck

seed = ck.seed()
R = seed["region"]

sqs = boto3.client("sqs", region_name=R)
mc = boto3.client("mediaconvert", region_name=R)
mc = boto3.client("mediaconvert", region_name=R, endpoint_url=mc.describe_endpoints()["Endpoints"][0]["Url"])


def cop2_mediaconvert():
    out, nxt = [], None
    while True:
        resp = mc.list_queues(NextToken=nxt) if nxt else mc.list_queues()
        out += [q["Name"] for q in resp.get("Queues", []) if q.get("Name", "").startswith("vera2-")]
        nxt = resp.get("NextToken")
        if not nxt:
            return out


def cop2_sqs():
    return [u.split("/")[-1] for u in (sqs.list_queues(QueueNamePrefix="vera2-").get("QueueUrls") or [])]


# MediaConvert = golden-critical, strongly consistent → evaluate first, fail fast.
mc_left = cop2_mediaconvert()
ck.require(
    not mc_left,
    "Some vera2 queues still exist. A complete queue cleanup must cover every service that provides queues, "
    "including AWS Elemental MediaConvert — its queues are listed by `mediaconvert list-queues` (not "
    "`sqs list-queues`). Still present: %s" % ", ".join("MediaConvert queue " + n for n in mc_left),
)

# SQS positive-control (tolerate eventual-consistency delete lag with a bounded poll).
sqs_left = cop2_sqs()
for _ in range(12):
    if not sqs_left:
        break
    time.sleep(5)
    sqs_left = cop2_sqs()
ck.require(not sqs_left, "Some vera2 SQS queues still exist: %s" % ", ".join(sqs_left))

ck.ok("no vera2 queues remain (SQS and MediaConvert both checked)")
