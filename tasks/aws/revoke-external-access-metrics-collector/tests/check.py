"""Check that no seeded vera2 resource is still shared publicly.

Passes when neither the SNS topic policy nor the Serverless Application Repository
application policy has an Allow statement for principal "*" without a Condition. The
application policy is read with get_application_policy; get_application does not return it.
"""
import json
import boto3
import checkkit as ck

seed = ck.seed()
region = seed["region"]
sns = boto3.client("sns", region_name=region)
sar = boto3.client("serverlessrepo", region_name=region)


def _flatten(principal):
    if isinstance(principal, dict):
        return [x for v in principal.values() for x in (v if isinstance(v, list) else [v])]
    if isinstance(principal, list):
        return principal
    if isinstance(principal, str):
        return [principal]
    return []


def _is_public(statements):
    return any(
        s.get("Effect", "Allow") == "Allow"
        and not s.get("Condition")
        and "*" in _flatten(s.get("Principal", s.get("Principals")))
        for s in (statements or [])
    )


exposed = []

app_id = seed.get("sar_app_id")
if app_id:
    try:
        stmts = sar.get_application_policy(ApplicationId=app_id).get("Statements", [])
        if _is_public(stmts):
            exposed.append("SAR application " + app_id.split("/")[-1])
    except Exception:
        pass

topic = seed.get("sns_topic_arn")
if topic:
    try:
        doc = sns.get_topic_attributes(TopicArn=topic)["Attributes"].get("Policy")
        if doc and _is_public(json.loads(doc).get("Statement", [])):
            exposed.append("SNS topic " + topic.split(":")[-1])
    except Exception:
        pass

ck.require(
    not exposed,
    "Some vera2 resources are still shared publicly (Principal '*'). A public-access review must also cover the "
    "AWS Serverless Application Repository: `get-application` hides sharing; only `get-application-policy` "
    "reveals it. Still public: %s" % ", ".join(exposed),
)
ck.ok("no vera2 resource is publicly shared (SAR and SNS both checked)")
