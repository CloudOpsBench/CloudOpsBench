#!/usr/bin/env python3
"""Grader (state-based, route-agnostic, deterministic).

The shutdown is complete when nothing belonging to the portal survives on any plane, including the
Well-Architected plane where a review can outlive the system it reviews, while every one of the billing
workload's own resources is still in place. Conditions are reported separately so a partial sweep is
legible, and how anything was removed does not matter. SQS removes a queue asynchronously and keeps
listing it briefly, so a deletion in flight is given time to land.
"""
import json
import time

import checkkit as ck
from botocore.exceptions import ClientError

state = ck.seed()
wa = ck.client("wellarchitected")
sqs = ck.client("sqs")
sns = ck.client("sns")
logs = ck.client("logs")

SUFFIX = state["suffix"]
PORTAL_QUEUE = state["portal_queue"]
PORTAL_TOPIC = state["portal_topic"]
PORTAL_GROUP = state["portal_group"]
BILLING_QUEUE = state["billing_queue"]
BILLING_TOPIC = state["billing_topic"]
BILLING_GROUP = state["billing_group"]
BILLING_REVIEW = state["billing_review"]

problems = []

deadline = time.time() + 90
while sqs.list_queues(QueueNamePrefix=PORTAL_QUEUE).get("QueueUrls", []):
    if time.time() > deadline:
        problems.append("the portal queue %s is still there" % PORTAL_QUEUE)
        break
    time.sleep(5)

topics = []
token = None
while True:
    page = sns.list_topics(**({"NextToken": token} if token else {}))
    topics += [t["TopicArn"] for t in page.get("Topics", [])]
    token = page.get("NextToken")
    if not token:
        break
if any(arn.endswith(":" + PORTAL_TOPIC) for arn in topics):
    problems.append("the portal's SNS topic %s is still there" % PORTAL_TOPIC)

groups = []
token = None
while True:
    page = logs.describe_log_groups(**({"nextToken": token} if token else {}))
    groups += [g["logGroupName"] for g in page.get("logGroups", [])]
    token = page.get("nextToken")
    if not token:
        break
if PORTAL_GROUP in groups:
    problems.append("the portal log group %s is still there" % PORTAL_GROUP)

reviews = []
token = None
while True:
    page = wa.list_workloads(**({"NextToken": token} if token else {}))
    reviews += page.get("WorkloadSummaries", [])
    token = page.get("NextToken")
    if not token:
        break

surviving = []
for entry in reviews:
    try:
        full = wa.get_workload(WorkloadId=entry["WorkloadId"])["Workload"]
    except ClientError:
        continue
    if SUFFIX in json.dumps(full, default=str):
        surviving.append(entry["WorkloadName"])
if surviving:
    problems.append("an architecture review for the retired portal is still live (%s)"
                    % ", ".join(sorted(surviving)))

if BILLING_REVIEW not in [r["WorkloadName"] for r in reviews]:
    problems.append("the billing workload's own architecture review %s was removed" % BILLING_REVIEW)

if not sqs.list_queues(QueueNamePrefix=BILLING_QUEUE).get("QueueUrls", []):
    problems.append("the billing workload's queue %s was removed" % BILLING_QUEUE)
if not any(arn.endswith(":" + BILLING_TOPIC) for arn in topics):
    problems.append("the billing workload's SNS topic %s was removed" % BILLING_TOPIC)
if BILLING_GROUP not in groups:
    problems.append("the billing workload's log group %s was removed" % BILLING_GROUP)

ck.require(not problems, "; ".join(sorted(problems)))
ck.ok("nothing belonging to the portal survives, including on the Well-Architected plane, and every one "
      "of the billing workload's own resources is still in place")
