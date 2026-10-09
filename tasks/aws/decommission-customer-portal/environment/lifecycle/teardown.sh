#!/usr/bin/env bash
set -uo pipefail

python3 - <<'PY'
import os
import uuid

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
wa = boto3.client("wellarchitected", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)
logs = boto3.client("logs", region_name=REGION)

token = None
while True:
    try:
        page = wa.list_workloads(**({"NextToken": token} if token else {}))
    except ClientError:
        break
    for entry in page.get("WorkloadSummaries", []):
        if entry["WorkloadName"].startswith("vera2"):
            try:
                wa.delete_workload(WorkloadId=entry["WorkloadId"],
                                   ClientRequestToken=uuid.uuid4().hex)
            except ClientError:
                pass
    token = page.get("NextToken")
    if not token:
        break

for url in sqs.list_queues(QueueNamePrefix="vera2-").get("QueueUrls", []):
    try:
        sqs.delete_queue(QueueUrl=url)
    except ClientError:
        pass

token = None
while True:
    page = sns.list_topics(**({"NextToken": token} if token else {}))
    for entry in page.get("Topics", []):
        if entry["TopicArn"].rsplit(":", 1)[-1].startswith("vera2-"):
            try:
                sns.delete_topic(TopicArn=entry["TopicArn"])
            except ClientError:
                pass
    token = page.get("NextToken")
    if not token:
        break

token = None
while True:
    try:
        page = logs.describe_log_groups(logGroupNamePrefix="/vera2/",
                                        **({"nextToken": token} if token else {}))
    except ClientError:
        break
    for group in page.get("logGroups", []):
        try:
            logs.delete_log_group(logGroupName=group["logGroupName"])
        except ClientError:
            pass
    token = page.get("nextToken")
    if not token:
        break

print("teardown done")
PY
