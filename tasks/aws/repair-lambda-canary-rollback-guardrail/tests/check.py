#!/usr/bin/env python3
"""Check the canary rollback guardrail on the seeded Lambda deployment.

Passes when the live alias targets only the stable version, the deployment group uses
the required canary config with rollback on failure and on the seeded alarm, the alarm
and CodeDeploy role are scoped to the live alias, and seeded resources and tags are intact.
"""
import json, os, sys, urllib.parse
import boto3
from botocore.exceptions import ClientError

errors=[]
def fail(x): errors.append(x)
def load():
    for p in [os.path.join(os.environ.get("AGENT_WORKSPACE",""),"task_context.json"),"task_context.json"]:
        if p and os.path.isfile(p): return json.load(open(p))
    raise SystemExit("CHECK FAILED\n1. task_context.json not found")
c=load(); r=c["region"]
la=boto3.client("lambda",region_name=r); cd=boto3.client("codedeploy",region_name=r); cw=boto3.client("cloudwatch",region_name=r); iam=boto3.client("iam",region_name=r)

def statements(policy):
    values=policy.get("Statement", [])
    return values if isinstance(values, list) else [values]

def values(value):
    return set(value if isinstance(value, list) else [value])

def decode(document):
    return json.loads(urllib.parse.unquote(document)) if isinstance(document, str) else document

def action_matches(grant, required):
    grant=grant.lower(); required=required.lower()
    return grant == "*" or grant == required or (grant.endswith("*") and required.startswith(grant[:-1]))

def resource_matches(grant, required):
    return grant == "*" or grant == required

def usable_allow(statement, action, resource, exact_resource=False):
    """True for an unconditional Allow covering the action and resource.

    Conditioned statements are not accepted, since a condition may make the grant unusable.
    """
    if statement.get("Effect") != "Allow" or statement.get("Condition"):
        return False
    if not any(action_matches(grant, action) for grant in values(statement.get("Action", []))):
        return False
    resources=values(statement.get("Resource", []))
    return resource in resources if exact_resource else any(resource_matches(grant, resource) for grant in resources)

def policy_allows(policy, action, resource, exact_resource=False):
    return any(
        usable_allow(statement, action, resource, exact_resource)
        for statement in statements(policy)
    )

def grants_broader_alias_access(policy, action, required_alias):
    """True if any Allow for the action covers a resource other than the required alias."""
    for statement in statements(policy):
        if statement.get("Effect") != "Allow":
            continue
        if any(action_matches(grant, action) for grant in values(statement.get("Action", []))):
            if any(str(resource) != required_alias for resource in values(statement.get("Resource", []))):
                return True
    return False

def policy_denies(policy, action, resource):
    """True if a conditionless Deny covers the action and resource."""
    return any(
        statement.get("Effect") == "Deny"
        and not statement.get("Condition")
        and any(action_matches(grant, action) for grant in values(statement.get("Action", [])))
        and any(resource_matches(grant, resource) for grant in values(statement.get("Resource", [])))
        for statement in statements(policy)
    )

def role_policy_documents(role_name):
    documents=[]
    for name in iam.list_role_policies(RoleName=role_name).get("PolicyNames", []):
        documents.append(decode(iam.get_role_policy(RoleName=role_name, PolicyName=name)["PolicyDocument"]))
    for attachment in iam.list_attached_role_policies(RoleName=role_name).get("AttachedPolicies", []):
        metadata=iam.get_policy(PolicyArn=attachment["PolicyArn"])["Policy"]
        documents.append(decode(iam.get_policy_version(
            PolicyArn=attachment["PolicyArn"], VersionId=metadata["DefaultVersionId"]
        )["PolicyVersion"]["Document"]))
    return documents

try:
    cfg=la.get_function_configuration(FunctionName=c["function_name"])
    expected=c["function_configuration"]
    for key,value in expected.items():
        if cfg.get(key)!=value: fail("Seeded function configuration changed: "+key)
    if cfg.get("FunctionArn")!=c["function_arn"]: fail("Seeded function identity changed")
    if cfg.get("CodeSha256")!=c["code_sha256"]: fail("The seeded function code was changed")
except ClientError as e: fail("Unable to read seeded function: "+str(e))

try:
    a=la.get_alias(FunctionName=c["function_name"],Name=c["alias_name"])
    if a.get("AliasArn")!=c["alias_arn"]: fail("Seeded alias changed")
    if a.get("FunctionVersion")!=c["stable_version"]: fail("live alias must target the seeded stable version")
    if a.get("RoutingConfig",{}).get("AdditionalVersionWeights"): fail("live alias must not have an additional routing weight")
except ClientError as e: fail("Unable to read live alias: "+str(e))

for version_name in ("stable_version", "candidate_version"):
    try:
        version=la.get_function(FunctionName=c["function_name"], Qualifier=c[version_name])["Configuration"]
        if version.get("Version") != c[version_name]: fail("Seeded published version is missing: "+version_name)
    except ClientError as e: fail("Seeded published version is missing: "+version_name)

try:
    info=cd.get_deployment_group(applicationName=c["application_name"],deploymentGroupName=c["deployment_group_name"])["deploymentGroupInfo"]
    if info.get("deploymentGroupId") != c.get("deployment_group_id"): fail("Seeded deployment group was replaced")
    application=cd.get_application(applicationName=c["application_name"]).get("application", {})
    if application.get("applicationId") != c.get("application_id"): fail("Seeded CodeDeploy application was replaced")
    if info.get("serviceRoleArn")!=c["deploy_role_arn"]: fail("Deployment group uses the wrong CodeDeploy role")
    if info.get("deploymentConfigName")!="CodeDeployDefault.LambdaCanary10Percent5Minutes": fail("Deployment group must use the required Lambda canary configuration")
    style=info.get("deploymentStyle",{})
    if style.get("deploymentType")!="BLUE_GREEN" or style.get("deploymentOption")!="WITH_TRAFFIC_CONTROL": fail("Deployment group must use Lambda traffic control")
    rollback=info.get("autoRollbackConfiguration",{})
    if not rollback.get("enabled") or not {"DEPLOYMENT_FAILURE","DEPLOYMENT_STOP_ON_ALARM"}.issubset(set(rollback.get("events",[]))): fail("Deployment group must roll back for failures and alarm breaches")
    alarm=info.get("alarmConfiguration",{})
    names={x.get("name") for x in alarm.get("alarms",[])}
    if not alarm.get("enabled") or alarm.get("ignorePollAlarmFailure") is not False or names!={c["alarm_name"]}: fail("Deployment group must monitor only the seeded alarm")
except ClientError as e: fail("Unable to read deployment group: "+str(e))

try:
    alarms=cw.describe_alarms(AlarmNames=[c["alarm_name"]]).get("MetricAlarms",[])
    if len(alarms)!=1: fail("Seeded CloudWatch alarm missing")
    else:
        a=alarms[0]; dims={d["Name"]:d["Value"] for d in a.get("Dimensions",[])}
        one_error=(a.get("Threshold")==1 and a.get("ComparisonOperator")=="GreaterThanOrEqualToThreshold") or (a.get("Threshold")==0 and a.get("ComparisonOperator")=="GreaterThanThreshold")
        checks=[(a.get("Namespace")=="AWS/Lambda","Alarm must use AWS/Lambda"),(a.get("MetricName")=="Errors","Alarm must measure Errors"),(a.get("Statistic")=="Sum","Alarm must use Sum"),(a.get("Period")==60,"Alarm period must be 60 seconds"),(a.get("EvaluationPeriods")==1,"Alarm evaluation periods must be one"),(one_error,"Alarm must alarm on one error"),(a.get("TreatMissingData")=="notBreaching","Alarm must treat missing data as not breaching"),(dims=={"FunctionName":c["function_name"],"Resource":f"{c['function_name']}:{c['alias_name']}"},"Alarm must be scoped to the live alias")]
        for ok,msg in checks:
            if not ok: fail(msg)
except ClientError as e: fail("Unable to read alarm: "+str(e))

try:
    role=iam.get_role(RoleName=c["deploy_role_name"])["Role"]
    if role.get("RoleId") != c.get("deploy_role_id"): fail("Seeded CodeDeploy role was replaced")
    trust=role["AssumeRolePolicyDocument"]; sts=trust.get("Statement",[]); sts=sts if isinstance(sts,list) else [sts]
    allowed=[s for s in sts if s.get("Effect")=="Allow"]
    if (len(allowed)!=1
        or values(allowed[0].get("Principal",{}).get("Service", [])) != {"codedeploy.amazonaws.com"}
        or values(allowed[0].get("Action", [])) != {"sts:AssumeRole"}):
        fail("CodeDeploy role must trust only codedeploy.amazonaws.com")
    docs=role_policy_documents(c["deploy_role_name"])
    if not docs: fail("CodeDeploy role needs deployment permissions")
    effective={"Version":"2012-10-17","Statement":[s for doc in docs for s in statements(doc)]}
    required_alias=f"{c['function_arn']}:{c['alias_name']}"
    if not policy_allows(effective,"lambda:UpdateAlias",required_alias, exact_resource=True): fail("CodeDeploy role cannot update the live alias with an unconditional alias-scoped grant")
    if not policy_allows(effective,"lambda:GetAlias",required_alias, exact_resource=True): fail("CodeDeploy role cannot read the live alias with an unconditional alias-scoped grant")
    if not policy_allows(effective,"cloudwatch:DescribeAlarms","*"): fail("CodeDeploy role cannot monitor alarms")
    for action in ("lambda:UpdateAlias", "lambda:GetAlias"):
        if grants_broader_alias_access(effective, action, required_alias):
            fail("CodeDeploy role grants " + action + " outside the seeded live alias")
    for action, resource in [("lambda:UpdateAlias", required_alias), ("lambda:GetAlias", required_alias), ("cloudwatch:DescribeAlarms", "*")]:
        if policy_denies(effective, action, resource): fail("CodeDeploy role explicitly denies a required deployment action")
    permitted={"cloudwatch:describealarms","lambda:updatealias","lambda:getalias","lambda:getprovisionedconcurrencyconfig","sns:publish","s3:getobject","s3:getobjectversion","lambda:invokefunction"}
    for statement in statements(effective):
        if statement.get("Effect") != "Allow": continue
        for action in values(statement.get("Action", [])):
            if str(action).lower() not in permitted: fail("CodeDeploy role grants an unrelated action: "+str(action))
except ClientError as e: fail("Unable to read CodeDeploy role: "+str(e))

expected={"CloudOpTask":c["task_tag"],"Owner":c["owner"],"SecurityProfile":"secure-canary-rollback-v1"}
execution_role=iam.get_role(RoleName=c["execution_role_name"])["Role"]
if execution_role.get("RoleId") != c.get("execution_role_id"): fail("Seeded Lambda execution role was replaced")
for label,tags in [("function",la.list_tags(Resource=c["function_arn"]).get("Tags",{})),("CodeDeploy role",{x["Key"]:x["Value"] for x in iam.list_role_tags(RoleName=c["deploy_role_name"]).get("Tags",[])}),("Lambda execution role",{x["Key"]:x["Value"] for x in iam.list_role_tags(RoleName=c["execution_role_name"]).get("Tags",[])})]:
    wanted=expected if label != "Lambda execution role" else {"CloudOpTask":c["task_tag"],"Owner":c["owner"]}
    for k,v in wanted.items():
        if tags.get(k)!=v: fail(f"{label} tag {k} missing or changed")
if errors:
    print("CHECK FAILED")
    for i,e in enumerate(errors,1): print(f"{i}. {e}")
    sys.exit(1)
print("CHECK PASSED")
