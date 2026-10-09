"""Grader: the legacy automation role is fully retired. Everything that
operated through it (nightly schedule, build project, launch capacity from the
launch template's default version, the release-gate delegation, the artifact
read grant) now operates through the replacement role; no policy still carries
a reference to the legacy role (including dead AROA leftovers); protected
neighbors (metrics schedule, compliance-scan access, the artifact object) are
untouched; and the legacy role is deleted. Grades only what prompt.txt states
and accepts every valid fix shape: the launch capacity may be fixed by swapping
the role inside the profile, moving $Default to the migrated version, or a new
version/profile, as long as default launches come up under the replacement;
access grants may live in the bucket policy or in identity policies."""
import fnmatch
import json

import botocore.exceptions

import checkkit as ck

iam = ck.client("iam")
scheduler = ck.client("scheduler")
codebuild = ck.client("codebuild")
events = ck.client("events")
ssm = ck.client("ssm")
ec2 = ck.client("ec2")
s3 = ck.client("s3")
sqs = ck.client("sqs")
seed = ck.seed()

ACCT = seed["account"]
LEGACY_ROLE = seed["legacy_role"]
LEGACY_ARN = seed["legacy_role_arn"]
NEW_ROLE = seed["new_role"]
NEW_ARN = seed["new_role_arn"]
BUCKET = seed["bucket"]
QARN = seed["queue_arn"]
ROOT_ARN = "arn:aws:iam::%s:root" % ACCT
TEST_OBJ = "arn:aws:s3:::%s/%s" % (BUCKET, seed["artifact_key"])


def role_exists(name):
    try:
        iam.get_role(RoleName=name)
        return True
    except botocore.exceptions.ClientError as e:
        if e.response.get("Error", {}).get("Code") == "NoSuchEntity":
            return False
        raise


def as_list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def identity_allows(role_arn, action, resource):
    try:
        res = iam.simulate_principal_policy(
            PolicySourceArn=role_arn, ActionNames=[action],
            ResourceArns=[resource])
    except botocore.exceptions.ClientError:
        return False
    return all(r["EvalDecision"] == "allowed"
               for r in res["EvaluationResults"])


# --- The legacy role is deleted (prompt 4).
ck.require(not role_exists(LEGACY_ROLE),
           "the legacy role %s still exists; the retirement ends with its "
           "deletion (prompt 4)" % LEGACY_ROLE)

# --- Nothing else was deleted (prompt 3).
for name, label in ((NEW_ROLE, "replacement role"),
                    (seed["gate_role"], "release gate role"),
                    (seed["compliance_role"], "compliance scan role"),
                    (seed["metrics_role"], "metrics agent role"),
                    (seed["sfn_role"], "flow execution role")):
    ck.require(role_exists(name),
               "the %s (%s) is gone; only the legacy role was to be deleted"
               % (label, name))

# --- Nightly schedule fires through the replacement role (prompt 1).
try:
    sch = scheduler.get_schedule(Name=seed["schedule"])
except botocore.exceptions.ClientError:
    ck.fail("the nightly schedule %s is gone; the job had to keep running, "
            "just through the replacement role" % seed["schedule"])
ck.require(sch.get("State") == "ENABLED",
           "the nightly schedule %s is not ENABLED; the job had to keep "
           "running" % seed["schedule"])
target = sch.get("Target", {})
ck.require(target.get("Arn") == QARN,
           "the nightly schedule no longer targets the fleet events queue "
           "(target: %r); only its role was to change" % target.get("Arn"))
ck.require(target.get("RoleArn") == NEW_ARN,
           "the nightly schedule still fires with role %r: its next run "
           "breaks now that the legacy role is deleted. It had to fire "
           "through the replacement role (prompt 1)" % target.get("RoleArn"))
ck.require(sch.get("ScheduleExpression") == seed["schedule_expression"],
           "the nightly schedule's expression changed to %r: only its role "
           "was to change, the job itself had to keep running exactly as it "
           "does today (prompt 3)" % sch.get("ScheduleExpression"))
ck.require(target.get("Input") == seed["schedule_input"],
           "the nightly schedule's job payload changed (Input: %r): only its "
           "role was to change, the job itself had to keep running exactly "
           "as it does today (prompt 3)" % target.get("Input"))

# --- Protected hourly schedule untouched (prompt 3).
try:
    prot = scheduler.get_schedule(Name=seed["schedule_protected"])
except botocore.exceptions.ClientError:
    ck.fail("the hourly metrics schedule %s is gone; it was not part of the "
            "migration and had to keep working" % seed["schedule_protected"])
ck.require(prot.get("State") == "ENABLED"
           and prot.get("Target", {}).get("RoleArn") == seed["metrics_role_arn"]
           and prot.get("Target", {}).get("Arn") == QARN,
           "the hourly metrics schedule was modified; it runs through its own "
           "role and was not part of the migration (prompt 3)")

# --- The inventory kick rule on the platform event bus fires its flow through
#     the replacement role (prompt 1). It lives on a custom bus.
try:
    rule = events.describe_rule(Name=seed["bus_rule"],
                                EventBusName=seed["event_bus"])
except botocore.exceptions.ClientError:
    ck.fail("the inventory rule %s on the platform event bus is gone; the "
            "flow had to keep firing, just through the replacement role"
            % seed["bus_rule"])
ck.require(rule.get("State") == "ENABLED",
           "the inventory rule %s on the platform event bus is not ENABLED; "
           "the flow had to keep firing" % seed["bus_rule"])
bus_targets = events.list_targets_by_rule(
    Rule=seed["bus_rule"], EventBusName=seed["event_bus"]).get("Targets", [])
ck.require(bus_targets and bus_targets[0].get("Arn") == seed["sfn_arn"],
           "the inventory rule no longer targets the inventory flow; only "
           "its role was to change (prompt 3)")
ck.require(bus_targets[0].get("RoleArn") == NEW_ARN,
           "the inventory rule on the platform event bus still fires its "
           "flow with role %r: its next firing breaks now that the legacy "
           "role is deleted. It had to fire through the replacement role "
           "(prompt 1)" % bus_targets[0].get("RoleArn"))

# --- CodeBuild project builds as the replacement role (prompt 1).
projects = codebuild.batch_get_projects(
    names=[seed["codebuild_project"]]).get("projects", [])
ck.require(projects,
           "the build project %s is gone; it had to keep working through the "
           "replacement role" % seed["codebuild_project"])
sr = projects[0].get("serviceRole")
ck.require(sr == NEW_ARN or sr == NEW_ARN.replace(":role/", ":role/service-role/"),
           "the build project %s still runs as %r: its next build breaks now "
           "that the legacy role is deleted. It had to run as the replacement "
           "role (prompt 1)" % (seed["codebuild_project"], sr))

# --- Launch capacity: whatever the launch template's $Default version resolves
#     to must put the REPLACEMENT role on new instances (prompt 1). Removing
#     the legacy role from the profile without putting the replacement in
#     leaves every future launch with no credentials at all.
try:
    versions = ec2.describe_launch_template_versions(
        LaunchTemplateId=seed["launch_template_id"],
        Versions=["$Default"])["LaunchTemplateVersions"]
except botocore.exceptions.ClientError:
    ck.fail("the fleet launch template is gone; launch capacity had to keep "
            "working through the replacement role")
lt_data = versions[0].get("LaunchTemplateData", {})
prof_ref = lt_data.get("IamInstanceProfile") or {}
prof_name = prof_ref.get("Name") or (prof_ref.get("Arn") or "").split("/")[-1]
ck.require(bool(prof_name),
           "the launch template's default version no longer attaches any "
           "instance profile: instances launched from it come up with no "
           "credentials, so the fleet's capacity silently stops working "
           "(prompt 1)")
try:
    prof_roles = [r["RoleName"] for r in iam.get_instance_profile(
        InstanceProfileName=prof_name)["InstanceProfile"]["Roles"]]
except botocore.exceptions.ClientError:
    ck.fail("the launch template's default version references instance "
            "profile %r, which does not exist: launches from it fail "
            "(prompt 1)" % prof_name)
ck.require(prof_roles,
           "instance profile %s (what the launch template's default version "
           "launches with) is EMPTY: removing the legacy role from it without "
           "putting the replacement in leaves every new instance with no "
           "credentials. Launch capacity had to keep working through the "
           "replacement role (prompt 1)" % prof_name)
ck.require(NEW_ROLE in prof_roles,
           "instances launched from the template's default version come up "
           "with role(s) %r, not the replacement role (prompt 1)" % prof_roles)

# --- Release-gate delegation: no dead reference, assumable by the replacement
#     (prompt 1 and 2).
gate_doc = iam.get_role(RoleName=seed["gate_role"])["Role"][
    "AssumeRolePolicyDocument"]
gate_txt = json.dumps(gate_doc)
ck.require("AROA" not in gate_txt and LEGACY_ARN not in gate_txt
           and LEGACY_ROLE not in gate_txt,
           "the release gate role's trust policy still references the legacy "
           "role (as a dead, unresolvable principal now that the role is "
           "deleted): no policy may still reference it (prompt 2), and the "
           "delegation that ran through the legacy role is broken (prompt 1)")
GATE_ARN = "arn:aws:iam::%s:role/%s" % (ACCT, seed["gate_role"])
trust_names_new = False
trust_names_root = False
for st in gate_doc.get("Statement", []):
    if st.get("Effect") != "Allow":
        continue
    actions = [a.lower() for a in as_list(st.get("Action"))]
    if not any(fnmatch.fnmatch("sts:assumerole", a) for a in actions):
        continue
    principal = st.get("Principal", {})
    aws_p = as_list(principal.get("AWS")) if isinstance(principal, dict) else []
    if NEW_ARN in aws_p:
        trust_names_new = True
    if ROOT_ARN in aws_p or "*" in aws_p:
        trust_names_root = True
# Naming the replacement role directly in the trust policy is sufficient for a
# same-account principal. A broader principal (account root) only works if the
# replacement ALSO holds identity-side sts:AssumeRole permission - without it
# the delegation is still broken, so simulate before accepting that shape.
gate_ok = trust_names_new or (
    trust_names_root and identity_allows(NEW_ARN, "sts:AssumeRole", GATE_ARN))
ck.require(gate_ok,
           "the release gate delegation is broken: the replacement role "
           "cannot actually assume it (the trust policy must name the "
           "replacement role, or a broader trust must be paired with "
           "identity-side sts:AssumeRole permission on the replacement). "
           "That access path operated through the legacy role and had to "
           "operate through the replacement instead (prompt 1)")

# --- Bucket policy: no legacy leftover; compliance scan keeps read access;
#     the replacement can read artifacts (prompt 1, 2, 3).
try:
    pol_txt = s3.get_bucket_policy(Bucket=BUCKET)["Policy"]
except botocore.exceptions.ClientError:
    pol_txt = None
if pol_txt is not None:
    ck.require("AROA" not in pol_txt and LEGACY_ARN not in pol_txt
               and LEGACY_ROLE not in pol_txt,
               "the artifact bucket policy still references the legacy role "
               "(now a dead AROA principal): no policy may still reference it "
               "(prompt 2)")


def bucket_grants(principal_arn):
    if pol_txt is None:
        return False
    for st in json.loads(pol_txt).get("Statement", []):
        if st.get("Effect") != "Allow":
            continue
        principal = st.get("Principal")
        if principal == "*":
            aws_p = ["*"]
        elif isinstance(principal, dict):
            aws_p = as_list(principal.get("AWS"))
        else:
            aws_p = []
        if principal_arn not in aws_p and "*" not in aws_p:
            continue
        actions = [a.lower() for a in as_list(st.get("Action"))]
        if not any(fnmatch.fnmatch("s3:getobject", a) for a in actions):
            continue
        if any(fnmatch.fnmatch(TEST_OBJ, r) for r in as_list(st.get("Resource"))):
            return True
    return False


ck.require(bucket_grants(seed["compliance_role_arn"])
           or identity_allows(seed["compliance_role_arn"], "s3:GetObject",
                              TEST_OBJ),
           "the compliance scan role lost its read access to the artifacts: "
           "the shared grant was its only access path, and nobody else's "
           "access was to be removed or weakened (prompt 3)")
ck.require(bucket_grants(NEW_ARN)
           or identity_allows(NEW_ARN, "s3:GetObject", TEST_OBJ),
           "the replacement role cannot read the fleet artifacts: the read "
           "access the legacy role had must work through the replacement "
           "(prompt 1)")

# --- Artifact object untouched (prompt 3).
try:
    body = s3.get_object(Bucket=BUCKET,
                         Key=seed["artifact_key"])["Body"].read()
except botocore.exceptions.ClientError:
    ck.fail("the artifact object %s is gone; nothing but the role migration "
            "was to change" % seed["artifact_key"])
ck.require(body.decode() == seed["artifact_content"],
           "the artifact object %s no longer has its original contents"
           % seed["artifact_key"])

# --- Archive replication runs through the replacement role (prompt 1). The
#     config lives in a bucket subresource; leaving it on the legacy role
#     breaks mirroring the moment the role is deleted.
try:
    repl = s3.get_bucket_replication(
        Bucket=BUCKET)["ReplicationConfiguration"]
except botocore.exceptions.ClientError:
    ck.fail("the artifact bucket's replication configuration is gone; the "
            "archive mirroring had to keep working, just through the "
            "replacement role (prompt 1 and 3)")
ck.require(repl.get("Role") == NEW_ARN,
           "the artifact bucket still replicates through role %r: mirroring "
           "breaks now that the legacy role is deleted. It had to run "
           "through the replacement role (prompt 1)" % repl.get("Role"))
ck.require(any(r.get("Status") == "Enabled"
               and seed["mirror_bucket"] in r.get("Destination", {}).get("Bucket", "")
               for r in repl.get("Rules", [])),
           "the archive replication rule was disabled or repointed; only its "
           "role was to change (prompt 3)")

# --- Patch-cycle maintenance window task runs as the replacement role
#     (prompt 1).
try:
    mw_enabled = ssm.get_maintenance_window(
        WindowId=seed["mw_id"]).get("Enabled")
except botocore.exceptions.ClientError:
    ck.fail("the patch cycle maintenance window is gone; the job had to keep "
            "running, just through the replacement role (prompt 1 and 3)")
ck.require(mw_enabled,
           "the patch cycle maintenance window was disabled; it had to keep "
           "running (prompt 3)")
mw_tasks = ssm.describe_maintenance_window_tasks(
    WindowId=seed["mw_id"]).get("Tasks", [])
ck.require(mw_tasks,
           "the patch cycle's registered task is gone; the job had to keep "
           "running, just through the replacement role (prompt 1 and 3)")
ck.require(mw_tasks[0].get("ServiceRoleArn") == NEW_ARN,
           "the patch cycle's task still runs with service role %r: its next "
           "window breaks now that the legacy role is deleted. It had to run "
           "through the replacement role (prompt 1)"
           % mw_tasks[0].get("ServiceRoleArn"))

# --- Queue untouched (prompt 3), and the replacement role can actually do the
#     nightly job's work (prompt 1).
try:
    sqs.get_queue_attributes(QueueUrl=seed["queue_url"],
                             AttributeNames=["QueueArn"])
except botocore.exceptions.ClientError:
    ck.fail("the fleet events queue is gone; nothing but the role migration "
            "was to change")
ck.require(identity_allows(NEW_ARN, "sqs:SendMessage", QARN),
           "the replacement role cannot send to the fleet events queue, so "
           "the nightly job's next firing fails; everything that operated "
           "through the legacy role had to keep working via the replacement "
           "(prompt 1)")

new_trust = iam.get_role(RoleName=NEW_ROLE)["Role"]["AssumeRolePolicyDocument"]
trusted_services = set()
for st in new_trust.get("Statement", []):
    if st.get("Effect") != "Allow":
        continue
    if "sts:AssumeRole" not in [a for a in as_list(st.get("Action"))]:
        continue
    principal = st.get("Principal", {})
    if isinstance(principal, dict):
        for svc in as_list(principal.get("Service")):
            trusted_services.add(svc)
# Every service that assumes the replacement through a migrated consumer must
# be able to: ssm (maintenance window), events (bus rule), scheduler, codebuild,
# ec2 (launch template), s3 (replication). The legacy role trusted all six.
for svc, why in (
        ("ssm.amazonaws.com",
         "the patch-cycle maintenance window's task"),
        ("events.amazonaws.com", "the inventory-flow event rule"),
        ("scheduler.amazonaws.com", "the nightly schedule"),
        ("codebuild.amazonaws.com", "the build project"),
        ("ec2.amazonaws.com", "instances from the launch template"),
        ("s3.amazonaws.com", "bucket replication")):
    ck.require(svc in trusted_services,
               "the replacement role's trust policy does not allow %s to "
               "assume it, so %s silently stops working the moment the legacy "
               "role is gone: the workload was repointed to a role that cannot "
               "actually run it. The replacement was provisioned but not able "
               "to do everything the legacy role did (prompt 1)" % (svc, why))

ck.require(identity_allows(NEW_ARN, "states:StartExecution", seed["sfn_arn"]),
           "the replacement role cannot start the inventory flow, so the "
           "inventory rule's next firing silently fails even though it now "
           "names the replacement role: the workload was repointed to a role "
           "that lacks the permission to run it. The replacement was "
           "provisioned but not able to do everything the legacy role did "
           "(prompt 1)")

# --- No policy anywhere may still reference the legacy role (prompt 2): scan
#     every role's trust document account-wide and the task roles' identity
#     policies for the legacy ARN, name, or unique role id (what a dead
#     principal degrades to after deletion). The tokens are seed-unique, so
#     ambient account resources cannot false-positive.
LEGACY_TOKENS = [LEGACY_ARN, LEGACY_ROLE, seed["legacy_role_id"]]


def has_legacy_token(text):
    return any(tok in text for tok in LEGACY_TOKENS)


for page in iam.get_paginator("list_roles").paginate():
    for r in page["Roles"]:
        if has_legacy_token(json.dumps(r.get("AssumeRolePolicyDocument", {}))):
            ck.fail("role %s's trust policy still references the legacy role "
                    "(by ARN, name, or as a dead unique-id leftover): no "
                    "policy may still reference it (prompt 2)" % r["RoleName"])

for name in (NEW_ROLE, seed["gate_role"], seed["compliance_role"],
             seed["metrics_role"]):
    for pn in iam.list_role_policies(RoleName=name)["PolicyNames"]:
        doc = iam.get_role_policy(RoleName=name, PolicyName=pn)
        if has_legacy_token(json.dumps(doc["PolicyDocument"])):
            ck.fail("role %s's policy %s still references the legacy role: "
                    "no policy may still reference it (prompt 2)" % (name, pn))

# --- Off-sweep reference: the dispatcher's automation-role ARN lives in an SSM
#     parameter VALUE, not in any IAM output. It is an access path (prompt 1)
#     and a configuration reference (prompt 2), so it must point at the
#     replacement, not the deleted legacy role.
try:
    runner_val = ssm.get_parameter(
        Name=seed["param_runner"])["Parameter"]["Value"]
except botocore.exceptions.ClientError:
    ck.fail("the dispatcher's runner-role parameter %s is gone; the "
            "automation access path had to keep working through the "
            "replacement role, not be deleted (prompt 1)" % seed["param_runner"])
ck.require(not has_legacy_token(runner_val),
           "the dispatcher still reads the legacy role ARN from %s (value: "
           "%r): the platform assumes that role to run, so this access path "
           "breaks the moment the legacy role is deleted, and no configuration "
           "may still reference it (prompt 1 and 2)"
           % (seed["param_runner"], runner_val))
ck.require(runner_val == NEW_ARN,
           "the dispatcher's runner-role parameter %s no longer names the "
           "replacement role (value: %r); the automation path had to move to "
           "the replacement (prompt 1)" % (seed["param_runner"], runner_val))

# --- Restraint (fair confusion): the sibling parameter names the PROTECTED
#     metrics role and must stay - a blind "replace every role ARN" fix that
#     repoints it breaks reporting (prompt 3).
try:
    report_val = ssm.get_parameter(
        Name=seed["param_report"])["Parameter"]["Value"]
except botocore.exceptions.ClientError:
    ck.fail("the dispatcher's reporting-role parameter %s is gone; it was not "
            "part of the migration and had to keep working (prompt 3)"
            % seed["param_report"])
ck.require(report_val == seed["metrics_role_arn"],
           "the dispatcher's reporting-role parameter %s was changed (value: "
           "%r); it points at the protected metrics role and was not part of "
           "the migration - nobody else's access was to be weakened (prompt 3)"
           % (seed["param_report"], report_val))

ck.ok("legacy role fully retired: schedule, build project, default-version "
      "launch capacity, release-gate delegation, and artifact access all run "
      "through the replacement; no dead references; protected neighbors "
      "untouched; legacy role deleted")
