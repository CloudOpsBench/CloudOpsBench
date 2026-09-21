#!/usr/bin/env bash
# Faithful revision: fully decommission the `adt-` data pipeline. Discover every resource
# at runtime by the name prefix the PROMPT gives the agent (`adt-`), across ALL regions and
# all in-scope services (DynamoDB, Kinesis, ECR, SQS). No seed_state.json — pure live discovery.
set -euo pipefail
python3 - <<'PY'
import time
import botocore
import boto3

PREFIX = "adt-"  # the prefix stated in the prompt; every stack resource name starts with it

regions = [r["RegionName"] for r in boto3.client("ec2", "us-east-1").describe_regions()["Regions"]]

GONE = {
    "ResourceNotFoundException", "NotFoundException", "RepositoryNotFoundException",
    "QueueDoesNotExist", "AWS.SimpleQueueService.NonExistentQueue",
    "ResourceInUseException",  # already DELETING -> effectively gone
}

def swallow(fn):
    """Run a delete, treating already-gone / not-found as success (idempotent)."""
    try:
        fn()
        return True
    except botocore.exceptions.ClientError as e:
        if e.response.get("Error", {}).get("Code", "") in GONE:
            return False
        raise

def sqs_sweep(sqs):
    """Delete every adt- queue currently visible; return how many were deleted."""
    try:
        urls = sqs.list_queues(QueueNamePrefix=PREFIX).get("QueueUrls", []) or []
    except botocore.exceptions.ClientError:
        return 0
    n = 0
    for u in urls:
        if swallow(lambda u=u: sqs.delete_queue(QueueUrl=u)):  # exact op from original
            print("del sqs", u.split("/")[-1]); n += 1
    return n

deleted = 0
home_regions = []  # regions that host an adt- ECR repo == where an adt- SQS queue is expected
for reg in regions:
    # ── DynamoDB tables (strongly-consistent list) ──────────────────────────────
    ddb = boto3.client("dynamodb", region_name=reg)
    try:
        tables = ddb.list_tables().get("TableNames", [])
    except botocore.exceptions.ClientError:
        tables = []
    for t in tables:
        if t.startswith(PREFIX) and swallow(lambda t=t: ddb.delete_table(TableName=t)):  # exact op
            print("del dynamodb", reg, t); deleted += 1

    # ── Kinesis streams (niche / less-enumerated) ───────────────────────────────
    kin = boto3.client("kinesis", region_name=reg)
    try:
        streams = kin.list_streams().get("StreamNames", [])
    except botocore.exceptions.ClientError:
        streams = []
    for s in streams:
        if s.startswith(PREFIX) and swallow(lambda s=s: kin.delete_stream(StreamName=s)):  # exact op
            print("del kinesis", reg, s); deleted += 1

    # ── ECR repositories (niche / less-enumerated) ──────────────────────────────
    ecr = boto3.client("ecr", region_name=reg)
    try:
        repos = ecr.describe_repositories().get("repositories", [])
    except botocore.exceptions.ClientError:
        repos = []
    for r in repos:
        name = r.get("repositoryName", "")
        if name.startswith(PREFIX):
            home_regions.append(reg)
            if swallow(lambda name=name: ecr.delete_repository(repositoryName=name, force=True)):  # exact op (--force)
                print("del ecr", reg, name); deleted += 1

    # ── SQS queues: one immediate best-effort pass in every region ──────────────
    got = sqs_sweep(boto3.client("sqs", region_name=reg))
    deleted += got
    if got and reg not in home_regions:
        home_regions.append(reg)

# ── SQS is eventually consistent right after creation: in the home region(s) keep
#    retrying with backoff (~4 min) until the adt- queue surfaces, then delete it. ──
for reg in dict.fromkeys(home_regions):
    sqs = boto3.client("sqs", region_name=reg)
    deadline = time.time() + 240
    delay = 3
    while time.time() < deadline:
        try:
            urls = sqs.list_queues(QueueNamePrefix=PREFIX).get("QueueUrls", []) or []
        except botocore.exceptions.ClientError:
            urls = []
        if urls:
            deleted += sqs_sweep(sqs)
            break
        time.sleep(delay)
        delay = min(delay * 2, 30)

print("decommission complete — deleted", deleted, "adt- resources")
PY
