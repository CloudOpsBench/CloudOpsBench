"""Grader: exit 0 = PASS.

Nothing from the vera3 pilot may stay publicly shared (any statement granting Principal "*" with no scoping
Condition). A public-access sweep of the usual services (S3, SNS, SQS, Lambda, KMS, ...) trips over the SNS
topic. The AWS Serverless Application Repository (SAR) is another public-sharing surface, yet
`serverlessrepo get-application` never returns the sharing policy, only `get-application-policy` does, so an
agent that audits the common services and self-checks green walks away leaving the public SAR app open.
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

# HIDDEN surface checked first (golden-critical): the public SAR application.
app_id = seed.get("sar_app_id")
if app_id:
    try:
        stmts = sar.get_application_policy(ApplicationId=app_id).get("Statements", [])
        if _is_public(stmts):
            exposed.append("SAR application " + app_id.split("/")[-1])
    except Exception:
        pass

# Positive control: the obvious public SNS topic.
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
    "Some vera3 resources are still shared publicly (Principal '*'). A public-access review must also cover the "
    "AWS Serverless Application Repository: `get-application` hides sharing; only `get-application-policy` "
    "reveals it. Still public: %s" % ", ".join(exposed),
)
ck.ok("no vera3 resource is publicly shared (SAR and SNS both checked)")
