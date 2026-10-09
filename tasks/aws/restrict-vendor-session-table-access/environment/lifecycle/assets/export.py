"""Meridian catalog export. Deployed by Meridian; configuration comes from job arguments."""
import json
import sys

import boto3


def arg(name):
    flag = "--" + name
    for i, a in enumerate(sys.argv):
        if a == flag and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    raise SystemExit("missing argument %s" % flag)


role_arn = arg("data-role-arn")
policy = arg("session-policy")
table = arg("source-table")
region = arg("data-region")

c = boto3.client("sts").assume_role(RoleArn=role_arn, RoleSessionName="meridian-export",
                                    Policy=policy)["Credentials"]
ddb = boto3.client("dynamodb", region_name=region,
                   aws_access_key_id=c["AccessKeyId"],
                   aws_secret_access_key=c["SecretAccessKey"],
                   aws_session_token=c["SessionToken"])
items = []
for page in ddb.get_paginator("scan").paginate(TableName=table):
    items.extend(page.get("Items", []))
print(json.dumps({"table": table, "rows": len(items)}))
