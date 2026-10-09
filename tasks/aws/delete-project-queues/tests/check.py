"""Check that every vera2 queue is gone from both SQS and MediaConvert.

Passes when `mediaconvert list-queues` and `sqs list-queues` return no vera2- queues.
SQS list-queues is eventually consistent after a delete, so that check is polled.
"""
import time
import boto3
import checkkit as ck

seed = ck.seed()
R = seed["region"]

sqs = boto3.client("sqs", region_name=R)
mc = boto3.client("mediaconvert", region_name=R)
mc = boto3.client("mediaconvert", region_name=R, endpoint_url=mc.describe_endpoints()["Endpoints"][0]["Url"])


def list_mediaconvert_queues():
    out, nxt = [], None
    while True:
        resp = mc.list_queues(NextToken=nxt) if nxt else mc.list_queues()
        out += [q["Name"] for q in resp.get("Queues", []) if q.get("Name", "").startswith("vera2-")]
        nxt = resp.get("NextToken")
        if not nxt:
            return out


def list_sqs_queues():
    return [u.split("/")[-1] for u in (sqs.list_queues(QueueNamePrefix="vera2-").get("QueueUrls") or [])]


# MediaConvert listing is strongly consistent, so it is checked first.
mc_left = list_mediaconvert_queues()
ck.require(
    not mc_left,
    "Some vera2 queues still exist. A complete queue cleanup must cover every service that provides queues, "
    "including AWS Elemental MediaConvert — its queues are listed by `mediaconvert list-queues` (not "
    "`sqs list-queues`). Still present: %s" % ", ".join("MediaConvert queue " + n for n in mc_left),
)

# SQS list-queues can lag after a delete; poll for up to a minute.
sqs_left = list_sqs_queues()
for _ in range(12):
    if not sqs_left:
        break
    time.sleep(5)
    sqs_left = list_sqs_queues()
ck.require(not sqs_left, "Some vera2 SQS queues still exist: %s" % ", ".join(sqs_left))

ck.ok("no vera2 queues remain (SQS and MediaConvert both checked)")
