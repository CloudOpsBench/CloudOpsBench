#!/usr/bin/env bash
# Deletes every EventBridge rule, SNS topic and SQS queue whose name contains
# the aeb-<region> prefix, across all regions, without reading seed_state.json.
# SQS listing is eventually consistent after both create and delete, so queue
# deletion is retried until list-queues no longer returns the prefix.
set -uo pipefail
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
PREFIX="aeb-${AWS_REGION}"

echo "==> decommissioning prefix '$PREFIX' across all regions"
PREFIX="$PREFIX" python3 - <<'PY'
import os, time, boto3
from botocore.exceptions import ClientError

prefix = os.environ["PREFIX"]
regions = [r["RegionName"] for r in boto3.client("ec2", "us-east-1").describe_regions()["Regions"]]
deleted = 0

def q_matches(reg):
    """URLs of prefix-matching queues currently visible in `reg` (best-effort)."""
    try:
        urls = boto3.client("sqs", region_name=reg).list_queues(
            QueueNamePrefix=prefix).get("QueueUrls", []) or []
    except ClientError:
        return []
    return [u for u in urls if prefix in u.rsplit("/", 1)[-1]]

def q_delete(reg, url):
    try:
        boto3.client("sqs", region_name=reg).delete_queue(QueueUrl=url)
        return True
    except ClientError:
        return False

# Strongly consistent services, across all regions.
home = []   # regions hosting an aeb- rule/topic (== where an aeb- queue exists too)
for reg in regions:
    hit = False
    # EventBridge rules: remove targets before deleting
    ev = boto3.client("events", region_name=reg)
    try:
        rules = ev.list_rules().get("Rules", [])
    except ClientError:
        rules = []
    for r in rules:
        name = r.get("Name", "")
        if prefix not in name:
            continue
        hit = True
        try:
            tids = [t["Id"] for t in ev.list_targets_by_rule(Rule=name).get("Targets", [])]
            if tids:
                ev.remove_targets(Rule=name, Ids=tids, Force=True)
        except ClientError:
            pass
        try:
            ev.delete_rule(Name=name, Force=True)
            print(f"  del events {reg} {name}"); deleted += 1
        except ClientError:
            pass

    # SNS topics
    sns = boto3.client("sns", region_name=reg)
    try:
        arns = [t["TopicArn"] for page in sns.get_paginator("list_topics").paginate()
                for t in page.get("Topics", [])]
    except ClientError:
        arns = []
    for arn in arns:
        if prefix not in arn.rsplit(":", 1)[-1]:
            continue
        hit = True
        try:
            sns.delete_topic(TopicArn=arn)
            print(f"  del sns {reg} {arn.rsplit(':',1)[-1]}"); deleted += 1
        except ClientError:
            pass

    if hit or q_matches(reg):
        home.append(reg)
home = list(dict.fromkeys(home))

# Reconcile SQS in home regions only, interleaving regions so the per-queue
# create and delete consistency windows (~60s each) overlap instead of summing. Leave a
# region only once list-queues no longer reports the prefix.
pending = list(home)
deadline = time.time() + 210
while pending and time.time() < deadline:
    still = []
    for reg in pending:
        urls = q_matches(reg)
        for u in urls:
            if q_delete(reg, u):
                print(f"  del sqs {reg} {u.rsplit('/',1)[-1]}"); deleted += 1
        if q_matches(reg):     # re-list: any straggler (not-yet-appeared, or delete not propagated)
            still.append(reg)
    pending = still
    if pending:
        time.sleep(6)

print(f"==> decommission complete — {deleted} resource(s) with prefix '{prefix}' removed"
      + (f" (WARNING: SQS still listing in {pending} at exit)" if pending else ""))
PY
