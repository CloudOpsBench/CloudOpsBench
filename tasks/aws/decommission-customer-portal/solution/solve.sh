#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import json
import os
import re
import time
import uuid

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
wa = boto3.client("wellarchitected", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)
logs = boto3.client("logs", region_name=REGION)

PORTAL = re.compile(r"vera2-portal-([0-9a-f]{8})")
suffixes = set()

for url in sqs.list_queues(QueueNamePrefix="vera2-portal-").get("QueueUrls", []):
    match = PORTAL.search(url)
    if match:
        suffixes.add(match.group(1))

topics = []
token = None
while True:
    page = sns.list_topics(**({"NextToken": token} if token else {}))
    topics += [t["TopicArn"] for t in page.get("Topics", [])]
    token = page.get("NextToken")
    if not token:
        break
for arn in topics:
    match = PORTAL.search(arn)
    if match:
        suffixes.add(match.group(1))

groups = []
token = None
while True:
    page = logs.describe_log_groups(**({"nextToken": token} if token else {}))
    groups += [g["logGroupName"] for g in page.get("logGroups", [])]
    token = page.get("nextToken")
    if not token:
        break
for name in groups:
    match = re.search(r"/vera2/portal/([0-9a-f]{8})", name)
    if match:
        suffixes.add(match.group(1))

reviews = []
token = None
while True:
    page = wa.list_workloads(**({"NextToken": token} if token else {}))
    reviews += page.get("WorkloadSummaries", [])
    token = page.get("NextToken")
    if not token:
        break
for entry in reviews:
    try:
        full = wa.get_workload(WorkloadId=entry["WorkloadId"])["Workload"]
    except ClientError:
        continue
    if any(sfx in json.dumps(full, default=str) for sfx in suffixes):
        wa.delete_workload(WorkloadId=entry["WorkloadId"], ClientRequestToken=uuid.uuid4().hex)

for url in sqs.list_queues(QueueNamePrefix="vera2-portal-").get("QueueUrls", []):
    sqs.delete_queue(QueueUrl=url)

for arn in topics:
    if PORTAL.search(arn):
        sns.delete_topic(TopicArn=arn)

for name in groups:
    if name.startswith("/vera2/portal/"):
        logs.delete_log_group(logGroupName=name)

deadline = time.time() + 90
while sqs.list_queues(QueueNamePrefix="vera2-portal-").get("QueueUrls", []):
    if time.time() > deadline:
        break
    time.sleep(5)

print("took the portal out, including the architecture review that outlived it")
PY
