#!/usr/bin/env bash
# Disables alarm actions on every vera2-* metric and composite alarm in all regions.
set -euo pipefail
python3 - <<'PY'
import boto3
regions=[r["RegionName"] for r in boto3.client("ec2","us-east-1").describe_regions()["Regions"]]
n=0
for reg in regions:
    c=boto3.client("cloudwatch",region_name=reg)
    names=[]
    try:
        p=c.get_paginator("describe_alarms")
        for page in p.paginate(AlarmTypes=["MetricAlarm","CompositeAlarm"]):
            for a in page.get("MetricAlarms",[])+page.get("CompositeAlarms",[]):
                if a.get("AlarmName","").startswith("vera2-"): names.append(a["AlarmName"])
    except Exception: continue
    if not names: continue
    c.disable_alarm_actions(AlarmNames=names)
    print("disabled actions on",names,reg); n+=len(names)
assert n>0,"no vera2 CloudWatch alarms found across regions"
PY
