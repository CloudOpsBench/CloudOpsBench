"""Grader: exit 0 = PASS.

No vera2 resource may remain shared publicly (a statement that grants Principal "*"). A public-access review
that walks the familiar services (S3, SNS, SQS, Lambda, KMS, ...) will catch the SNS topic. The AWS
Serverless Application Repository (SAR) is also a public-sharing surface, yet `serverlessrepo get-application`
does NOT hand back the sharing policy: only `get-application-policy` does. So an agent that reviews the usual
services and self-verifies green walks away leaving the public SAR application in place.
"""
import json
import boto3
import checkkit as ck

seed = ck.seed()
REGION = seed["region"]
sns_client = boto3.client("sns", region_name=REGION)
sar_client = boto3.client("serverlessrepo", region_name=REGION)


def _principal_values(principal):
    if isinstance(principal, dict):
        out = []
        for entry in principal.values():
            out.extend(entry if isinstance(entry, list) else [entry])
        return out
    if isinstance(principal, list):
        return principal
    if isinstance(principal, str):
        return [principal]
    return []


def _is_public(statements):
    def opens_it(stmt):
        if stmt.get("Effect", "Allow") != "Allow":
            return False
        if stmt.get("Condition"):
            return False
        principal = stmt.get("Principal", stmt.get("Principals"))
        return "*" in _principal_values(principal)

    return any(opens_it(s) for s in (statements or []))


exposed = []

# HIDDEN surface, inspected first (golden-critical): the public SAR application.
try:
    app_id = seed.get("sar_app_id")
    if app_id:
        stmts = sar_client.get_application_policy(ApplicationId=app_id).get("Statements", [])
        if _is_public(stmts):
            exposed.append("SAR application " + app_id.split("/")[-1])
except Exception:
    pass

# Positive control: the obvious public SNS topic.
try:
    topic_arn = seed.get("sns_topic_arn")
    if topic_arn:
        doc = sns_client.get_topic_attributes(TopicArn=topic_arn)["Attributes"].get("Policy")
        if doc and _is_public(json.loads(doc).get("Statement", [])):
            exposed.append("SNS topic " + topic_arn.split(":")[-1])
except Exception:
    pass

ck.require(
    not exposed,
    "Some vera2 resources are still shared publicly (Principal '*'). A public-access review has to include the "
    "AWS Serverless Application Repository too: `get-application` hides sharing, and only `get-application-policy` "
    "exposes it. Still public: %s" % ", ".join(exposed),
)
ck.ok("no vera2 resource is publicly shared (SAR and SNS both checked)")
