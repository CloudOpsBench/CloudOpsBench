#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import os
import time
import uuid

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
wa = boto3.client("wellarchitected", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)
logs = boto3.client("logs", region_name=REGION)
tagging = boto3.client("resourcegroupstaggingapi", region_name=REGION)

sfx = uuid.uuid4().hex[:8]
gen = uuid.uuid4().hex[:8]

PORTAL_QUEUE = "vera2-portal-%s-events" % sfx
PORTAL_TOPIC = "vera2-portal-%s-alerts" % sfx
PORTAL_GROUP = "/vera2/portal/%s" % sfx
PORTAL_REVIEW = "vera2-portal-%s" % sfx
PORTAL_OWNER = "portal-%s-oncall@example.com" % sfx

BILLING_QUEUE = "vera2-billing-%s-invoices" % gen
BILLING_TOPIC = "vera2-billing-%s-alerts" % gen
BILLING_GROUP = "/vera2/billing/%s" % gen
BILLING_REVIEW = "vera2-billing-%s" % gen
BILLING_OWNER = "billing-oncall@example.com"

if sfx in BILLING_REVIEW or gen in PORTAL_REVIEW:
    raise SystemExit("seed self-check failed: the two workload ids collide")


def review(name, description, owner):
    return wa.create_workload(
        WorkloadName=name,
        Description=description,
        Environment="PRODUCTION",
        AwsRegions=[REGION],
        ReviewOwner=owner,
        Lenses=["wellarchitected"],
        ClientRequestToken=uuid.uuid4().hex)["WorkloadId"]


PORTAL_REVIEW_ID = review(PORTAL_REVIEW,
                          "Production architecture review for the customer portal", PORTAL_OWNER)
BILLING_REVIEW_ID = review(BILLING_REVIEW,
                           "Production architecture review for the billing workload", BILLING_OWNER)

for queue in (PORTAL_QUEUE, BILLING_QUEUE):
    sqs.create_queue(QueueName=queue)
for topic in (PORTAL_TOPIC, BILLING_TOPIC):
    sns.create_topic(Name=topic)
for group in (PORTAL_GROUP, BILLING_GROUP):
    logs.create_log_group(logGroupName=group)
    logs.put_retention_policy(logGroupName=group, retentionInDays=30)

live = {w["WorkloadName"]: w for w in wa.list_workloads().get("WorkloadSummaries", [])}
for name in (PORTAL_REVIEW, BILLING_REVIEW):
    if name not in live:
        raise SystemExit("seed self-check failed: the review %s was not created" % name)

described = wa.get_workload(WorkloadId=PORTAL_REVIEW_ID)["Workload"]
if described.get("ReviewOwner") != PORTAL_OWNER:
    raise SystemExit("seed self-check failed: the portal review is not owned by %s (%s)"
                     % (PORTAL_OWNER, described.get("ReviewOwner")))
if described.get("Tags"):
    raise SystemExit("seed self-check failed: the portal review carries tags, so a tag inventory "
                     "would return it")

found = []
for page in tagging.get_paginator("get_resources").paginate():
    found += [r["ResourceARN"] for r in page.get("ResourceTagMappingList", [])]
if any(PORTAL_REVIEW_ID in arn for arn in found):
    raise SystemExit("seed self-check failed: the tagging inventory returns the portal's review, so "
                     "the standard cross-service sweep would reach the Well-Architected plane")

visible = [t["TopicArn"] for t in sns.list_topics().get("Topics", [])]
if not any(arn.endswith(":" + BILLING_TOPIC) for arn in visible):
    raise SystemExit("seed self-check failed: the billing workload has no visible topic, which would "
                     "turn the preservation clause into a search instruction")

deadline = time.time() + 60
while not sqs.list_queues(QueueNamePrefix=PORTAL_QUEUE).get("QueueUrls", []):
    if time.time() > deadline:
        raise SystemExit("seed self-check failed: %s never appeared in the queue listing"
                         % PORTAL_QUEUE)
    time.sleep(3)

state = {
    "suffix": sfx,
    "generation": gen,
    "portal_queue": PORTAL_QUEUE,
    "portal_topic": PORTAL_TOPIC,
    "portal_group": PORTAL_GROUP,
    "portal_review": PORTAL_REVIEW,
    "portal_review_id": PORTAL_REVIEW_ID,
    "portal_owner": PORTAL_OWNER,
    "billing_queue": BILLING_QUEUE,
    "billing_topic": BILLING_TOPIC,
    "billing_group": BILLING_GROUP,
    "billing_review": BILLING_REVIEW,
    "billing_review_id": BILLING_REVIEW_ID,
}
with open("seed_state.json", "w") as handle:
    json.dump(state, handle)

print("seeded: the portal owns %s, %s, %s and an architecture review still assigned to %s; the billing "
      "workload owns %s, %s, %s and its own review"
      % (PORTAL_QUEUE, PORTAL_TOPIC, PORTAL_GROUP, PORTAL_OWNER,
         BILLING_QUEUE, BILLING_TOPIC, BILLING_GROUP))
PY
