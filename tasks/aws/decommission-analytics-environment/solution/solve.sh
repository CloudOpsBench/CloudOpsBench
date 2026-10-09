#!/usr/bin/env bash
# Deletes every Athena work-group, secret, SSM parameter and SQS queue whose name carries
# the `aaq-7c21` prefix, in all regions. SQS list_queues is eventually consistent after
# create, so the retry with backoff runs only in regions where another matching resource
# was found; retrying in every region would exceed the time limit.
set -euo pipefail
python3 - <<'PY'
import time
import boto3
from botocore.exceptions import ClientError

PREFIX = "aaq-7c21"

regions = [r["RegionName"] for r in boto3.client("ec2", "us-east-1").describe_regions()["Regions"]]
deleted = 0

def has_prefix(name):
    return isinstance(name, str) and PREFIX in name

def sqs_sweep(reg):
    """Delete every matching queue currently visible in `reg`; return count deleted."""
    sqs = boto3.client("sqs", region_name=reg)
    try:
        urls = sqs.list_queues(QueueNamePrefix=PREFIX).get("QueueUrls", []) or []
    except ClientError:
        return 0
    n = 0
    for u in urls:
        if not has_prefix(u.rsplit("/", 1)[-1]):
            continue
        try:
            sqs.delete_queue(QueueUrl=u)
            print("del sqs:", reg, u); n += 1
        except ClientError as e:
            print("skip sqs:", reg, u, e.response["Error"].get("Code"))
    return n

# Strongly consistent services, across all regions.
pending_sqs = []   # HOME regions whose eventually-consistent queue wasn't visible yet
for reg in regions:
    hit = False
    # Athena work-groups
    try:
        ath = boto3.client("athena", region_name=reg)
        tok = None
        wgs = []
        while True:
            resp = ath.list_work_groups(**({"NextToken": tok} if tok else {}))
            wgs += [w.get("Name", "") for w in resp.get("WorkGroups", [])]
            tok = resp.get("NextToken")
            if not tok:
                break
        for name in wgs:
            if not has_prefix(name):
                continue
            hit = True
            try:
                ath.delete_work_group(WorkGroup=name, RecursiveDeleteOption=True)
                print("del athena wg:", reg, name); deleted += 1
            except ClientError as e:
                print("skip athena wg:", reg, name, e.response["Error"].get("Code"))
    except ClientError:
        pass

    # Secrets Manager
    try:
        sm = boto3.client("secretsmanager", region_name=reg)
        for page in sm.get_paginator("list_secrets").paginate():
            for s in page.get("SecretList", []):
                if not has_prefix(s.get("Name", "")):
                    continue
                hit = True
                try:
                    sm.delete_secret(SecretId=s["Name"], ForceDeleteWithoutRecovery=True)
                    print("del secret:", reg, s["Name"]); deleted += 1
                except ClientError as e:
                    print("skip secret:", reg, s["Name"], e.response["Error"].get("Code"))
    except ClientError:
        pass

    # SSM parameters
    try:
        ssm = boto3.client("ssm", region_name=reg)
        for page in ssm.get_paginator("describe_parameters").paginate():
            for par in page.get("Parameters", []):
                nm = par.get("Name", "")
                if not has_prefix(nm):
                    continue
                hit = True
                try:
                    ssm.delete_parameter(Name=nm)
                    print("del ssm:", reg, nm); deleted += 1
                except ClientError as e:
                    print("skip ssm:", reg, nm, e.response["Error"].get("Code"))
    except ClientError:
        pass

    # one immediate best-effort SQS pass (the queue may already be consistent)
    got = sqs_sweep(reg)
    deleted += got
    if hit and got == 0:
        pending_sqs.append(reg)

# SQS is eventually consistent: retry with backoff in home regions still missing the queue.
for reg in dict.fromkeys(pending_sqs):
    deadline, delay = time.time() + 180, 3
    while time.time() < deadline:
        got = sqs_sweep(reg)
        if got:
            deleted += got
            break
        time.sleep(delay); delay = min(delay * 2, 20)

print("total deleted:", deleted)
assert deleted > 0, f"no resources carrying '{PREFIX}' found in any region"
PY
