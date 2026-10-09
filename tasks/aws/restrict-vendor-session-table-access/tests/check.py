"""Grader. Each integration path is judged by the scoping document it currently stores,
evaluated with the real IAM policy engine (simulate-custom-policy) together with the role
the path currently targets, so any document wording that produces the stated end state
passes and no fix shape is graded. Isolation is judged first; restraints follow.
Exit 0 = PASS."""
import json

import boto3
import botocore
import checkkit as ck

seed = ck.seed()
REGION = seed["region"]
MIRROR_REGION = seed["mirror_region"]
CATALOG_ARN = seed["catalog_arn"]
PRICING_ARN = seed["pricing_arn"]
ROLE = seed["role"]
ROLE_ARN = seed["role_arn"]
READ_ACTIONS = ("dynamodb:GetItem", "dynamodb:BatchGetItem",
                "dynamodb:Query", "dynamodb:Scan")
ROLE_KEEPS = READ_ACTIONS + ("dynamodb:DescribeTable",)

iam = boto3.client("iam", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
glue = boto3.client("glue", region_name=REGION)
cb = boto3.client("codebuild", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)
ecs = boto3.client("ecs", region_name=MIRROR_REGION)

_fails = []


def need(cond, msg):
    if not cond:
        _fails.append(msg)
    return bool(cond)


def decide(policies, action, resource_arn):
    """Real IAM evaluation of a set of policy documents."""
    if not policies:
        return "no-policy"
    try:
        r = iam.simulate_custom_policy(PolicyInputList=list(policies),
                                       ActionNames=[action], ResourceArns=[resource_arn])
    except Exception as exc:  # a document IAM will not parse cannot be a working fix
        return "invalid:%s" % exc
    return r["EvaluationResults"][0]["EvalDecision"]


def role_name_of(arn):
    return arn.rsplit("/", 1)[-1]


def role_policies(arn):
    """Everything a role grants, managed and inline. (None, why) when unreadable."""
    name = role_name_of(arn)
    docs = []
    try:
        for p in iam.list_attached_role_policies(RoleName=name).get("AttachedPolicies", []):
            pol = iam.get_policy(PolicyArn=p["PolicyArn"])["Policy"]
            v = iam.get_policy_version(PolicyArn=p["PolicyArn"],
                                       VersionId=pol["DefaultVersionId"])["PolicyVersion"]
            docs.append(json.dumps(v["Document"]))
        for n in iam.list_role_policies(RoleName=name).get("PolicyNames", []):
            docs.append(json.dumps(iam.get_role_policy(RoleName=name,
                                                       PolicyName=n)["PolicyDocument"]))
    except Exception as exc:
        return None, "the role %s could not be read (%s)" % (name, exc)
    return docs, None


def session_allows(doc_text, target_docs, action, arn):
    """Whether a session assumed with this stored document (or with none at all) can
    perform the action: the document AND the target role's own grant must both allow it."""
    role_side = decide(target_docs, action, arn)
    if doc_text is None or not doc_text.strip():
        return role_side == "allowed", ("no scoping document of its own, so the session "
                                        "carries the role's full grant, which evaluates %s"
                                        % role_side)
    doc_side = decide([doc_text], action, arn)
    if doc_side != "allowed":
        return False, "its scoping document evaluates %s" % doc_side
    if role_side != "allowed":
        return False, ("its scoping document allows it but the target role evaluates %s"
                       % role_side)
    return True, "both its scoping document and the target role evaluate allowed"


def judge_path(label, doc_text, target_role_arn, runner_role_arn, extra_evidence=""):
    if not need(target_role_arn == ROLE_ARN,
                "%s now assumes %s instead of the shared role %s. Each integration keeps the "
                "catalog access it has today through the path it uses today, so moving it onto "
                "a different role is a different path, not a narrower session."
                % (label, target_role_arn, ROLE_ARN)):
        return
    target_docs, why = role_policies(target_role_arn)
    if not need(why is None,
                "%s targets %s, but %s, so the path can no longer obtain a working session; "
                "every integration path has to keep working." % (label, target_role_arn, why)):
        return
    for action in READ_ACTIONS:
        allowed, ev = session_allows(doc_text, target_docs, action, PRICING_ARN)
        need(not allowed,
             "%s can still read the pricing table: %s for %s on %s. The task requires that "
             "no session a Meridian integration can obtain reads anything from it.%s"
             % (label, ev, action, PRICING_ARN, extra_evidence))
    for action in ROLE_KEEPS:
        allowed, ev = session_allows(doc_text, target_docs, action, CATALOG_ARN)
        need(allowed,
             "%s lost its catalog access: %s for %s on %s. The task requires every "
             "integration to keep the catalog read access it has today."
             % (label, ev, action, CATALOG_ARN))
    # The runner must still be able to assume what the path targets.
    runner_docs, why = role_policies(runner_role_arn)
    if not need(why is None,
                "%s runs as %s, but %s; the integration can no longer start."
                % (label, runner_role_arn, why)):
        return
    d = decide(runner_docs, "sts:AssumeRole", target_role_arn)
    need(d == "allowed",
         "%s runs as %s, whose policies evaluate %s for sts:AssumeRole on %s, so the "
         "integration can no longer obtain credentials at all."
         % (label, role_name_of(runner_role_arn), d, target_role_arn))
    for action in READ_ACTIONS:
        d = decide(runner_docs, action, PRICING_ARN)
        need(d != "allowed",
             "%s runs as %s, whose own policies evaluate allowed for %s on %s: that role's "
             "native credentials are a session the integration obtains, so a direct grant "
             "on the pricing table defeats the required end state."
             % (label, role_name_of(runner_role_arn), action, PRICING_ARN))


# ---------------------------------------------------------------- outcome: the three paths

# 1. Glue export job.
try:
    job = glue.get_job(JobName=seed["glue_job"])["Job"]
except Exception as exc:
    job = None
    _fails.append("the Glue job %s could not be read (%s); every Meridian integration path "
                  "has to still exist." % (seed["glue_job"], exc))
if job is not None:
    # Non-overridable arguments take precedence over defaults at run time, so a fix
    # applied through either surface counts.
    args = dict(job.get("DefaultArguments", {}) or {})
    args.update(job.get("NonOverridableArguments", {}) or {})
    judge_path("the catalog export job %s" % seed["glue_job"],
               args.get("--session-policy"),
               args.get("--data-role-arn") or ROLE_ARN,
               job.get("Role", ""))
    cmd = job.get("Command", {}) or {}
    need(cmd.get("ScriptLocation") == seed["script_location"],
         "the export job's script location changed from %s to %s; Meridian deploys its own "
         "integration code, so the fix belongs in the job's configuration."
         % (seed["script_location"], cmd.get("ScriptLocation")))
    try:
        head = s3.head_object(Bucket=seed["script_bucket"], Key=seed["script_key"])
        need(head["ETag"].strip('"') == seed["script_etag"],
             "the export script s3://%s/%s was rewritten (ETag %s, seeded %s); Meridian "
             "deploys its own integration code, so the fix belongs in the job's "
             "configuration, not in the script."
             % (seed["script_bucket"], seed["script_key"],
                head["ETag"].strip('"'), seed["script_etag"]))
    except botocore.exceptions.ClientError as exc:
        _fails.append("the export script s3://%s/%s is no longer readable (%s); the "
                      "integration can no longer run."
                      % (seed["script_bucket"], seed["script_key"], exc))

# 2. CodeBuild feed refresh.
try:
    projects = cb.batch_get_projects(names=[seed["codebuild_project"]])["projects"]
except Exception:
    projects = []
if not projects:
    _fails.append("the CodeBuild project %s no longer exists; every Meridian integration "
                  "path has to still exist." % seed["codebuild_project"])
else:
    proj = projects[0]
    env = {e["name"]: e["value"] for e in
           proj.get("environment", {}).get("environmentVariables", [])}
    judge_path("the feed refresh project %s" % seed["codebuild_project"],
               env.get("DATA_SESSION_POLICY"),
               env.get("DATA_ROLE_ARN") or ROLE_ARN,
               proj.get("serviceRole", ""))
    need(proj.get("source", {}).get("buildspec") == seed["buildspec"],
         "the feed refresh project's build commands were edited; Meridian deploys its own "
         "integration code, so the fix belongs in the project's configuration, not in the "
         "buildspec.")

def live_bindings(svc):
    """(label, task-definition) for every binding that can still run. A task set that was
    deleted, is draining, or is scaled to zero launches nothing and is not judged."""
    out = []
    for ts in svc.get("taskSets", []):
        if ts.get("status") not in ("PRIMARY", "ACTIVE"):
            continue
        scale = ts.get("scale", {}) or {}
        if float(scale.get("value", 0) or 0) <= 0:
            continue
        out.append(("task set %s (%s)" % (ts.get("id"), ts.get("status")),
                    ts.get("taskDefinition")))
    if not out and not svc.get("taskSets") and svc.get("taskDefinition"):
        out.append(("its task definition", svc["taskDefinition"]))
    return out


try:
    svcs = ecs.describe_services(cluster=seed["ecs_cluster"],
                                 services=[seed["ecs_service"]],
                                 include=["TAGS"])["services"]
    svc = svcs[0] if svcs and svcs[0].get("status") == "ACTIVE" else None
except Exception:
    svc = None
if svc is None:
    _fails.append("the service %s on cluster %s in %s no longer exists or is not active; "
                  "every Meridian integration path has to still exist."
                  % (seed["ecs_service"], seed["ecs_cluster"], MIRROR_REGION))
else:
    bindings = live_bindings(svc)
    need(bool(bindings),
         "the mirror worker service %s has nothing left that can launch a task (no live "
         "task set and no task definition of its own), so the integration was switched off "
         "rather than scoped; the task requires every integration to keep running through "
         "the path it uses today." % seed["ecs_service"])
    for _label, bound in bindings:
        try:
            td = ecs.describe_task_definition(taskDefinition=bound)["taskDefinition"]
        except Exception as exc:
            td = None
            _fails.append("the task definition %s that the service %s runs via %s could not be "
                          "read (%s)." % (bound, seed["ecs_service"], _label, exc))
        if td is not None:
            need(td.get("status") == "ACTIVE",
                 "the service %s is bound to %s, which is %s, so the service can no longer "
                 "launch its task; the integration path has to stay able to run."
                 % (seed["ecs_service"], bound, td.get("status")))
            cdefs = td.get("containerDefinitions", [])
            cd = next((c for c in cdefs if c.get("name") == seed["container_name"]),
                      cdefs[0] if cdefs else {})
            env = {e["name"]: e["value"] for e in cd.get("environment", [])}

            extra = ""
            doc_now = env.get("DATA_SESSION_POLICY")
            target_now = env.get("DATA_ROLE_ARN") or ROLE_ARN
            tdocs_now, _ = role_policies(target_now)
            still_broad = any(session_allows(doc_now, tdocs_now or [], a, PRICING_ARN)[0]
                              for a in READ_ACTIONS)
            if still_broad:
                try:
                    for arn in ecs.list_task_definitions(familyPrefix=seed["ecs_family"],
                                                         status="ACTIVE")["taskDefinitionArns"]:
                        if arn == td.get("taskDefinitionArn"):
                            continue
                        other = ecs.describe_task_definition(taskDefinition=arn)["taskDefinition"]
                        ocd = next((c for c in other.get("containerDefinitions", [])
                                    if c.get("name") == seed["container_name"]), None)
                        if not ocd:
                            continue
                        oenv = {e["name"]: e["value"] for e in ocd.get("environment", [])}
                        odoc = oenv.get("DATA_SESSION_POLICY")
                        otarget = oenv.get("DATA_ROLE_ARN") or ROLE_ARN
                        otdocs, _w = role_policies(otarget)
                        if otdocs is not None and not any(
                                session_allows(odoc, otdocs, a, PRICING_ARN)[0]
                                for a in READ_ACTIONS):
                            extra = (" A corrected revision exists (%s), but this binding "
                                     "still runs %s and is still live: task definitions are "
                                     "immutable, so registering a corrected one changes "
                                     "nothing until every live binding runs it and the ones "
                                     "that do not are removed or scaled to zero."
                                     % (arn, bound))
                            break
                except Exception:
                    pass
            judge_path("the mirror worker %s, running %s via %s"
                       % (seed["ecs_service"], bound.rsplit("/", 1)[-1], _label),
                       doc_now, target_now, td.get("taskRoleArn") or "", extra)
            need(cd.get("command") == seed["container_command"]
                 and cd.get("image") == seed["container_image"],
                 "the mirror task's container was edited (image or command differs from what "
                 "was seeded); Meridian deploys its own integration code, so the fix belongs "
                 "in the task definition's configuration, not in what the container runs.")

# ---------------------------------------------------------------- restraints

ROLE_DOCS, why = role_policies(ROLE_ARN)
if not need(why is None, "the shared role %s could not be read: %s" % (ROLE, why)):
    ROLE_DOCS = []
for arn in (CATALOG_ARN, PRICING_ARN):
    for action in ROLE_KEEPS:
        d = decide(ROLE_DOCS, action, arn)
        need(d == "allowed",
             "the shared role %s no longer grants %s on %s (evaluates %s). Reconciliation "
             "reads both tables through this role, so its own permissions had to stay as "
             "broad as they were." % (ROLE, action, arn, d))

try:
    trust = iam.get_role(RoleName=ROLE)["Role"]["AssumeRolePolicyDocument"]
    statements = ck.as_list(trust.get("Statement", []))
except Exception as exc:
    statements = []
    _fails.append("could not read the trust policy of %s: %s" % (ROLE, exc))

EQUIVALENT_OPS = {"arnlike": "stringlike", "arnequals": "stringequals",
                  "arnnotlike": "stringnotlike", "arnnotequals": "stringnotequals"}


def norm_condition(cond):
    if not cond:
        return {}
    out = {}
    for op, kv in cond.items():
        low = op.lower()
        out.setdefault(EQUIVALENT_OPS.get(low, low), {}).update(
            {k.lower(): sorted(ck.as_list(v)) for k, v in kv.items()})
    return out


def seeded_condition(principal):
    for st in ck.as_list(seed["trust_doc"].get("Statement", [])):
        pr = st.get("Principal", {}) or {}
        if principal in ck.as_list(pr.get("Service") or []) + ck.as_list(pr.get("AWS") or []):
            return st.get("Condition")
    return None


def still_assumable(principal):
    """An Allow of sts:AssumeRole for this principal carrying exactly the seeded condition,
    with nothing denying it. A new condition on a still-listed principal, or an explicit
    Deny appended after it, blocks the assumption just as removing the principal would."""
    blocked = None
    for st in statements:
        pr = st.get("Principal", {}) or {}
        named = ck.as_list(pr.get("Service") or []) + ck.as_list(pr.get("AWS") or [])
        actions = [a.lower() for a in ck.as_list(st.get("Action") or [])]
        if (st.get("Effect") == "Deny" and (principal in named or "*" in named)
                and any(a in ("sts:assumerole", "sts:*", "*") for a in actions)):
            return False, "an explicit Deny now blocks it: %s" % json.dumps(st)[:220]
    for st in statements:
        pr = st.get("Principal", {}) or {}
        named = ck.as_list(pr.get("Service") or []) + ck.as_list(pr.get("AWS") or [])
        if principal not in named:
            continue
        actions = [a.lower() for a in ck.as_list(st.get("Action") or [])]
        if not any(a in ("sts:assumerole", "sts:*", "*") for a in actions):
            continue
        if st.get("Effect") != "Allow":
            continue
        if norm_condition(st.get("Condition")) != norm_condition(seeded_condition(principal)):
            blocked = ("its Allow now carries the condition %s instead of %s"
                       % (json.dumps(st.get("Condition")),
                          json.dumps(seeded_condition(principal))))
            continue
        return True, None
    return False, blocked or "no statement allows it sts:AssumeRole any more"


for principal in ["arn:aws:iam::%s:root" % seed["account"]]:
    okp, whyp = still_assumable(principal)
    need(okp,
         "the trust policy of %s no longer lets %s assume it under the seeded condition: "
         "%s. Whatever could assume the role at the start still has to be able to."
         % (ROLE, principal, whyp))

# Reconciliation path.
recon_docs, why = role_policies(seed["recon_role_arn"])
if need(why is None,
        "the reconciliation role %s could not be read: %s; it has to keep its way in."
        % (seed["recon_role"], why)):
    d = decide(recon_docs, "sts:AssumeRole", ROLE_ARN)
    need(d == "allowed",
         "the reconciliation role %s can no longer assume %s (its policies evaluate %s); "
         "reconciliation has to keep its way in." % (seed["recon_role"], ROLE, d))

# Tables: untouched, no resource policies, data intact.
for tname, tarn in ((seed["catalog_table"], CATALOG_ARN),
                    (seed["pricing_table"], PRICING_ARN)):
    try:
        ddb.describe_table(TableName=tname)
    except Exception as exc:
        _fails.append("the table %s no longer exists (%s); the two tables stay as they "
                      "are." % (tname, exc))
        continue
    try:
        ddb.get_resource_policy(ResourceArn=tarn)
        _fails.append("the table %s now carries a resource-based policy; the task states "
                      "the tables must not change and the narrowing happens on the "
                      "credential paths." % tname)
    except botocore.exceptions.ClientError as exc:
        if exc.response["Error"]["Code"] not in ("PolicyNotFoundException",
                                                 "ResourceNotFoundException"):
            _fails.append("the resource policy of table %s could not be read (%s)."
                          % (tname, exc))
    want_cfg = (seed.get("table_config") or {}).get(tname)
    if want_cfg:
        t = ddb.describe_table(TableName=tname)["Table"]
        try:
            pitr = ddb.describe_continuous_backups(TableName=tname)[
                "ContinuousBackupsDescription"]["PointInTimeRecoveryDescription"][
                "PointInTimeRecoveryStatus"]
        except Exception:
            pitr = "DISABLED"
        got_cfg = {
            "billing_mode": (t.get("BillingModeSummary") or {}).get("BillingMode"),
            "deletion_protection": bool(t.get("DeletionProtectionEnabled")),
            "key_schema": t.get("KeySchema"),
            "attribute_definitions": t.get("AttributeDefinitions"),
            "sse": (t.get("SSEDescription") or {}).get("Status"),
            "stream": (t.get("StreamSpecification") or {}).get("StreamEnabled", False),
            "table_class": (t.get("TableClassSummary") or {}).get("TableClass"),
            "gsi": sorted(i["IndexName"] for i in t.get("GlobalSecondaryIndexes", []) or []),
            "lsi": sorted(i["IndexName"] for i in t.get("LocalSecondaryIndexes", []) or []),
            "pitr": pitr,
        }
        changed = sorted(k for k in want_cfg if got_cfg.get(k) != want_cfg[k])
        need(not changed,
             "the configuration of table %s changed (%s); the task states the two tables and "
             "their configuration stay as they are, and the narrowing happens on the credential "
             "paths. seeded: %s | now: %s"
             % (tname, ", ".join(changed),
                json.dumps({k: want_cfg[k] for k in changed}, sort_keys=True, default=str)[:200],
                json.dumps({k: got_cfg.get(k) for k in changed}, sort_keys=True,
                           default=str)[:200]))
    for pk, item in seed["items"][tname].items():
        try:
            got = ddb.get_item(TableName=tname, Key={"pk": {"S": pk}},
                               ConsistentRead=True).get("Item")
            need(got == item,
                 "the seeded item %s in table %s was modified (now %s); the tables' data "
                 "stays as it is." % (pk, tname, json.dumps(got)[:200]))
        except Exception as exc:
            _fails.append("the seeded item %s in table %s is no longer readable (%s)."
                          % (pk, tname, exc))

if _fails:
    ck.fail(" | ".join(_fails[:8]) + ("" if len(_fails) <= 8
                                      else " | (+%d more)" % (len(_fails) - 8)))
ck.ok("no session any Meridian integration can obtain reads the pricing table; every "
      "integration keeps its catalog access through its existing path, and the shared "
      "role, the reconciliation path and the tables are unchanged")
