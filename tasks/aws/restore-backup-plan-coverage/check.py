"""Grader for backup-optin-gap-task.

Grades only what prompt.txt states, and accepts every fix shape that gets
there. Nothing here reads or requires any particular opt-in setting, role
policy or tag - it runs what the nightly plan itself would run and grades the
outcome, so any route that produces the required end state passes.

Order is outcome first:

  1. requirement 1, functional - for every fleet resource the plan's selections
     currently match, start a backup job into the plan's vault with that
     selection's own role and require it to complete. This is the nightly run,
     executed rather than inferred.
  2. requirement 1, coverage - every fleet resource except the scratch bucket
     is matched by a selection on the plan.
  3. requirement 2 - the scratch bucket is either outside every selection on
     the plan, or a job for it is refused. Both are "not backed up by that
     plan"; either passes.
  4. requirement 3 - the plan, the vault and the fleet resources are the
     seeded ones.

Why real jobs, and not a permission check: neither an IAM policy simulation nor
a reading of the role can establish that a backup will actually run. Two things
AWS evaluates separately decide it, and both are seeded broken here:

  * the account-and-region resource-type opt-in
    (backup:DescribeRegionSettings). A type that is not opted in has its job
    refused at the API - "Resource type is not opted in" - with no job record
    created at all.
  * the target's own resource policy. vera-exports-* carries a file system
    policy that allows everything except elasticfilesystem:Backup, which it
    explicitly denies. AWS fails that job with "not authorized to perform:
    elasticfilesystem:Backup ... with an explicit deny in a resource-based
    policy" while every mount the policy allows keeps working.

A rollout that repairs the tag, the role's inline Deny and the opt-in, and then
concludes from an allowed IAM simulation that the backups will complete, has
left the second one in place. That is the intended miss, it is reproducible by
hand against live AWS, and a job started by this grader is the only thing that
can tell the two apart.
"""
import fnmatch
import time

import boto3
import botocore.exceptions
import checkkit as ck

s = ck.seed()
REGION = s["region"]
VAULT = s["vault"]
PLAN_ID = s["plan_id"]
PLAN = s["plan_name"]
PROTECTED = s["protected"]
EXCLUDED = s["excluded"]

backup = boto3.client("backup", region_name=REGION)
ddb = boto3.client("dynamodb", region_name=REGION)
efs = boto3.client("efs", region_name=REGION)
s3 = boto3.client("s3", region_name=REGION)

# EFS completes in ~25s and an empty table in ~2m45s, and the two table jobs run
# in parallel - but ~2m45s is one day's measurement, not a guarantee, and a
# correct fix must never fail on a slow AWS day. 420s is ~2.5x the observed worst
# case and still a fraction of the platform's ~600s grader ceiling.
JOB_DEADLINE = 420


def now():
    return time.strftime("%H:%M:%SZ", time.gmtime())


def label(arn):
    return arn.rsplit("/", 1)[-1]


def err(e):
    return f"{e.response['Error']['Code']}: {e.response['Error']['Message']}"


# --- what the plan selects right now ------------------------------------------
try:
    plan = backup.get_backup_plan(BackupPlanId=PLAN_ID)["BackupPlan"]
except botocore.exceptions.ClientError as e:
    ck.fail(f"backup plan {PLAN} ({PLAN_ID}) could not be read at grading time ({err(e)}); "
            f"requirement 3 is that the plan stays in place")

try:
    backup.describe_backup_vault(BackupVaultName=VAULT)
except botocore.exceptions.ClientError as e:
    ck.fail(f"backup vault {VAULT} could not be read at grading time ({err(e)}); "
            f"requirement 3 is that the vault stays in place")

selections = []
for meta in backup.list_backup_selections(BackupPlanId=PLAN_ID)["BackupSelectionsList"]:
    got = backup.get_backup_selection(BackupPlanId=PLAN_ID,
                                      SelectionId=meta["SelectionId"])["BackupSelection"]
    selections.append((meta["SelectionId"], got))
ck.require(selections,
           f"backup plan {PLAN} has no selections at grading time, so it protects nothing; "
           f"requirement 1 is that every fleet resource is covered by a selection on it")


def tags_of(arn):
    if ":dynamodb:" in arn:
        return {t["Key"]: t["Value"]
                for t in ddb.list_tags_of_resource(ResourceArn=arn).get("Tags", [])}
    if ":elasticfilesystem:" in arn:
        return {t["Key"]: t["Value"] for t in efs.list_tags_for_resource(
            ResourceId=arn.rsplit("/", 1)[-1]).get("Tags", [])}
    if arn.startswith("arn:aws:s3:::"):
        try:
            return {t["Key"]: t["Value"] for t in
                    s3.get_bucket_tagging(Bucket=arn.split(":::")[1])["TagSet"]}
        except botocore.exceptions.ClientError:
            return {}
    return {}


def arn_in(patterns, arn):
    return any(fnmatch.fnmatchcase(arn, p) for p in patterns or [])


def tag_key(condition_key):
    """A Conditions key is written aws:ResourceTag/<tag>; ListOfTags uses the
    bare tag name. Both name the same tag, so both read the same here."""
    key = condition_key or ""
    low = key.lower()
    for prefix in ("aws:resourcetag/", "aws:requesttag/"):
        if low.startswith(prefix):
            return key[len(prefix):]
    return key


def conditions_hold(sel, tags):
    """Conditions on a selection are AND-ed. Absent key never satisfies an equals."""
    cond = sel.get("Conditions") or {}
    for c in cond.get("StringEquals", []):
        if tags.get(tag_key(c["ConditionKey"])) != c["ConditionValue"]:
            return False
    for c in cond.get("StringLike", []):
        v = tags.get(tag_key(c["ConditionKey"]))
        if v is None or not fnmatch.fnmatchcase(v, c["ConditionValue"]):
            return False
    for c in cond.get("StringNotEquals", []):
        if tags.get(tag_key(c["ConditionKey"])) == c["ConditionValue"]:
            return False
    for c in cond.get("StringNotLike", []):
        v = tags.get(tag_key(c["ConditionKey"]))
        if v is not None and fnmatch.fnmatchcase(v, c["ConditionValue"]):
            return False
    return True


def tag_list_hits(sel, tags):
    """ListOfTags entries are OR-ed."""
    for c in sel.get("ListOfTags") or []:
        key, val = c["ConditionKey"], c["ConditionValue"]
        if c.get("ConditionType") == "STRINGEQUALS" and tags.get(key) == val:
            return True
        if c.get("ConditionType") != "STRINGEQUALS":
            v = tags.get(key)
            if v is not None and fnmatch.fnmatchcase(v, val):
                return True
    return False


def matching_selections(arn):
    """Every selection on the plan that would pick this resource up tonight."""
    tags = tags_of(arn)
    hits = []
    for sid, sel in selections:
        if arn_in(sel.get("NotResources"), arn):
            continue
        if not conditions_hold(sel, tags):
            continue
        by_arn = arn_in(sel.get("Resources"), arn)
        by_tag = tag_list_hits(sel, tags)
        # Resources empty means "everything", so a selection that narrows by
        # Conditions alone - a documented AWS Backup form - matches here too.
        bare = not sel.get("Resources") and not sel.get("ListOfTags")
        conds = sel.get("Conditions") or {}
        narrowed = any(conds.get(k) for k in
                       ("StringEquals", "StringLike", "StringNotEquals", "StringNotLike"))
        if by_arn or by_tag or (bare and narrowed):
            hits.append((sid, sel))
    return hits, tags


matches = {arn: matching_selections(arn) for arn in PROTECTED + [EXCLUDED]}


# --- requirement 1, functional: run what the nightly plan would run -----------
def start(arn, role_arn):
    return backup.start_backup_job(BackupVaultName=VAULT, ResourceArn=arn,
                                   IamRoleArn=role_arn)["BackupJobId"]


# A resource matched by more than one selection is backed up if ANY of them can
# do it, so every matching selection's role gets a turn before this is a refusal.
started, refused = {}, {}
for arn in PROTECTED:
    hits, _ = matches[arn]
    for sid, sel in hits:
        role = sel["IamRoleArn"]
        try:
            started[arn] = (start(arn, role), sid, role, now())
            refused.pop(arn, None)
            break
        except botocore.exceptions.ClientError as e:
            refused[arn] = (sid, role, err(e), now())


def abandon():
    """Nothing left to learn from a job once the run is already decided."""
    for job_id, _sid, _role, _at in started.values():
        try:
            backup.stop_backup_job(BackupJobId=job_id)
        except botocore.exceptions.ClientError:
            pass


# A refusal is already a final answer, so it is reported before the minutes of
# polling the other jobs would take.
for arn in PROTECTED:
    if arn in refused:
        sid, role, message, at = refused[arn]
        abandon()
        ck.fail(f"AWS said: {message} - refusing a backup job for {label(arn)}, which is "
                f"the job tonight's run of {PLAN} would start for it. Asked at {at}, into "
                f"vault {VAULT}, with {role}, the role on the selection ({sid}) that "
                f"matches this resource. So the plan cannot protect it, which requirement "
                f"1 requires. Resource ARN: {arn}")

pending = {arn: v[0] for arn, v in started.items()}
final = {}
deadline = time.time() + JOB_DEADLINE
while pending and time.time() < deadline:
    time.sleep(10)
    for arn, job_id in list(pending.items()):
        job = backup.describe_backup_job(BackupJobId=job_id)
        if job["State"] not in ("CREATED", "PENDING", "RUNNING"):
            final[arn] = (job["State"], job.get("StatusMessage", ""))
            pending.pop(arn)

for arn in PROTECTED:
    if arn not in started:
        continue  # not matched by any selection - reported as a coverage failure below
    job_id, sid, role, at = started[arn]
    if arn in pending:
        ck.fail(f"the backup job for {label(arn)} into {VAULT} (job {job_id}, started {at} "
                f"with {role} from selection {sid}) had still not finished {JOB_DEADLINE}s "
                f"later at {now()}; requirement 1 is that such a job completes")
    state, message = final[arn]
    ck.require(state == "COMPLETED",
               f"AWS said: {message or '<no status message>'} - the backup job for "
               f"{label(arn)} ended {state} rather than COMPLETED. Job {job_id}, started "
               f"{at} into {VAULT} with {role}, the role on selection {sid} that matches "
               f"this resource. Requirement 1 is that this job completes. Resource ARN: "
               f"{arn}")

# --- requirement 1, coverage --------------------------------------------------
for arn in PROTECTED:
    hits, tags = matches[arn]
    ck.require(hits,
               f"{label(arn)} is a fleet resource and no selection on {PLAN} matches it at "
               f"{now()}, so tonight's run backs it up not at all. Its tags are {tags or '{}'} "
               f"and the plan's selections are "
               f"{[{'id': sid, 'Resources': sel.get('Resources'), 'ListOfTags': sel.get('ListOfTags'), 'NotResources': sel.get('NotResources')} for sid, sel in selections]}. "
               f"Requirement 1 is that every fleet resource except the scratch bucket is "
               f"covered by a selection on this plan. Resource ARN: {arn}")

# --- requirement 2: the scratch bucket is still not backed up -----------------
vol_hits, vol_tags = matches[EXCLUDED]
if vol_hits:
    sid, sel = vol_hits[0]
    role = sel["IamRoleArn"]
    try:
        job_id = start(EXCLUDED, role)
    except botocore.exceptions.ClientError:
        job_id = None  # refused, so the nightly run cannot back it up either
    if job_id:
        try:
            backup.stop_backup_job(BackupJobId=job_id)
        except botocore.exceptions.ClientError:
            pass
        ck.fail(f"selection {sid} on {PLAN} matches {label(EXCLUDED)} (tags {vol_tags}) and "
                f"AWS Backup accepted a backup job for it into {VAULT} with that selection's "
                f"role {role} at {now()} (job {job_id}, stopped again by the grader). "
                f"Tonight's run would therefore back the scratch bucket up, which "
                f"requirement 2 forbids. Resource ARN: {EXCLUDED}")

points = []
paginator = backup.get_paginator("list_recovery_points_by_backup_vault")
for page in paginator.paginate(BackupVaultName=VAULT):
    points.extend(page["RecoveryPoints"])
vol_points = [p for p in points if p.get("ResourceArn") == EXCLUDED]
ck.require(not vol_points,
           f"vault {VAULT} holds {len(vol_points)} recovery point(s) for "
           f"{label(EXCLUDED)} at {now()} "
           f"({[p['RecoveryPointArn'] for p in vol_points][:3]}); requirement 2 is that the "
           f"scratch bucket is not backed up by {PLAN}")

# --- requirement 3: the seeded plan, vault and resources are still there ------
rule_vaults = {r.get("TargetBackupVaultName") for r in plan.get("Rules", [])}
ck.require(VAULT in rule_vaults,
           f"no rule on {PLAN} targets vault {VAULT} any more (rules target {rule_vaults}); "
           f"requirement 3 is that the plan and the vault stay in place")

try:
    live_ids = {n: ddb.describe_table(TableName=n)["Table"]["TableId"]
                for n in (s["table_orders"], s["table_audit"])}
    efs.describe_file_systems(FileSystemId=s["fs_id"])
    efs.describe_file_systems(FileSystemId=s["fs2_id"])
    live_scratch = [b["CreationDate"].isoformat() for b in s3.list_buckets()["Buckets"]
                    if b["Name"] == s["scratch_bucket"]][0]
    live_vault = backup.describe_backup_vault(
        BackupVaultName=VAULT)["CreationDate"].isoformat()
except botocore.exceptions.ClientError as e:
    ck.fail(f"a fleet resource seeded for this task is gone at grading time ({err(e)}); "
            f"requirement 3 is that the resources that exist now stay in place, not "
            f"deleted and recreated")

for name, seeded_id in s["table_ids"].items():
    ck.require(live_ids[name] == seeded_id,
               f"table {name} is not the one this task seeded: its id is now "
               f"{live_ids[name]}, seeded {seeded_id}, so it was deleted and recreated "
               f"under the same name. Requirement 3 forbids that.")
ck.require(live_scratch == s["scratch_created"],
           f"the bucket {s['scratch_bucket']} was created at {live_scratch}, but the one "
           f"this task seeded was created at {s['scratch_created']}, so it was deleted and "
           f"recreated under the same name. Requirement 3 forbids that.")
ck.require(live_vault == s["vault_created"],
           f"vault {VAULT} was created at {live_vault}, but the vault this task seeded "
           f"was created at {s['vault_created']}, so it was deleted and recreated under "
           f"the same name. Requirement 3 forbids that.")

done = ", ".join(f"{label(a)}={final[a][0]}" for a in PROTECTED if a in final)
ck.ok(f"every fleet resource is covered by a selection on {PLAN} and a real backup job for "
      f"it into {VAULT} completed ({done}); the scratch bucket is still not backed up; the "
      f"plan, the vault and the fleet resources are the seeded ones")
