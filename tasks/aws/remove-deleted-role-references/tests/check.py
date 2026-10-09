#!/usr/bin/env python3
"""Check that nothing in the account still names the retired role.

Passes when the Greengrass service-role association is unset or names a role that
existed before setup finished, no IAM policy document names the retired role, the
retired role has not been re-created, and the keep role is unchanged.
"""
import json
import time
import urllib.parse

import checkkit as ck
from botocore.exceptions import ClientError

state = ck.seed()
RETIRED_ARN = state["retired_role_arn"]
RETIRED = state["retired_role_name"]
KEEP = state["keep_role_name"]
SEEDED_AT = state.get("seeded_at")
KEEP_TRUST = state.get("keep_trust_policy")
KEEP_INLINE = state.get("keep_inline_policies") or {}
KEEP_SURFACE = state.get("keep_surface") or {}

gg = ck.client("greengrassv2")
iam = ck.client("iam")

def _doc(doc):
    """IAM hands a policy document back either URL-encoded or already decoded."""
    if isinstance(doc, str):
        try:
            return json.loads(urllib.parse.unquote(doc))
        except ValueError:
            return doc
    return doc


def _canon(x):
    """AWS does not preserve array order inside a policy document, so list members are ordered too."""
    if isinstance(x, dict):
        return {k: _canon(v) for k, v in x.items()}
    if isinstance(x, list):
        return sorted((_canon(v) for v in x), key=lambda v: json.dumps(v, sort_keys=True, default=str))
    return x


def _norm(doc):
    return json.dumps(_canon(_doc(doc)), sort_keys=True, default=str)


def _mentions(doc):
    return RETIRED in _norm(doc)


def _predates_handover(role_name):
    """True if the role exists and was created before setup finished."""
    try:
        cd = iam.get_role(RoleName=role_name)["Role"].get("CreateDate")
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            return False
        ck.fail("could not confirm the role %s: %s" % (role_name, e.response["Error"]["Code"]))
    if not SEEDED_AT or cd is None:
        return True
    return cd.timestamp() <= SEEDED_AT + 5


def _keep_unchanged():
    """Fail if the keep role is missing or any of its recorded attributes changed."""
    try:
        now = iam.get_role(RoleName=KEEP)["Role"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            ck.fail("the role %s was removed; it never named the retired role and was to be left alone"
                    % KEEP)
        ck.fail("could not confirm %s survived: %s" % (KEEP, e.response["Error"]["Code"]))
    if KEEP_TRUST is not None:
        ck.require(_norm(now.get("AssumeRolePolicyDocument")) == _norm(KEEP_TRUST),
                   "the trust policy of %s was modified; that role never named the retired role and was to "
                   "be left exactly as handed over" % KEEP)
    if KEEP_INLINE:
        try:
            names_now = set()
            for pg in iam.get_paginator("list_role_policies").paginate(RoleName=KEEP):
                names_now.update(pg.get("PolicyNames", []))
        except ClientError as e:
            ck.fail("could not read the inline policies of %s: %s" % (KEEP, e.response["Error"]["Code"]))
        ck.require(names_now == set(KEEP_INLINE),
                   "the inline policies of %s changed (expected %s, found %s); that role was to be left "
                   "exactly as handed over" % (KEEP, sorted(KEEP_INLINE), sorted(names_now)))
        for pname, doc in KEEP_INLINE.items():
            try:
                cur = iam.get_role_policy(RoleName=KEEP, PolicyName=pname)["PolicyDocument"]
            except ClientError as e:
                ck.fail("could not read inline policy %r of %s: %s"
                        % (pname, KEEP, e.response["Error"]["Code"]))
            ck.require(_norm(cur) == _norm(doc),
                       "the inline policy %r of %s was rewritten; that role was to be left exactly as "
                       "handed over" % (pname, KEEP))
    if KEEP_SURFACE:   # every mutable field, not just the policy documents
        now_attached = []
        try:
            for pg in iam.get_paginator("list_attached_role_policies").paginate(RoleName=KEEP):
                now_attached += [p["PolicyArn"] for p in pg.get("AttachedPolicies", [])]
        except ClientError as e:
            ck.fail("could not read the attached policies of %s: %s"
                    % (KEEP, e.response["Error"]["Code"]))
        surface_now = {"description": now.get("Description"),
                       "max_session_duration": now.get("MaxSessionDuration"),
                       "boundary": (now.get("PermissionsBoundary") or {}).get("PermissionsBoundaryArn"),
                       "tags": sorted([t["Key"], t["Value"]] for t in now.get("Tags") or []),
                       "attached": sorted(now_attached)}
        for field, was in KEEP_SURFACE.items():
            ck.require(_canon(surface_now.get(field)) == _canon(was),
                       "the %s of %s changed (was %r, now %r); that role never named the retired role and "
                       "was to be left exactly as handed over"
                       % (field.replace("_", " "), KEEP, was, surface_now.get(field)))


def _audit_account():
    """Fail if any role, user, group or customer-managed policy document names the retired role."""
    try:
        for page in iam.get_paginator("get_account_authorization_details").paginate(
                Filter=["Role", "User", "Group", "LocalManagedPolicy"]):
            for r in page.get("RoleDetailList", []):
                if (r.get("Path") or "/").startswith("/aws-service-role/"):
                    continue
                ck.require(not _mentions(r.get("AssumeRolePolicyDocument")),
                           "the trust policy of %s still names %s; the audit is to leave nothing in the "
                           "account naming that role" % (r["RoleName"], RETIRED))
                for pol in r.get("RolePolicyList", []):
                    ck.require(not _mentions(pol.get("PolicyDocument")),
                               "the inline policy %r of %s still names %s; the audit is to leave nothing "
                               "in the account naming that role"
                               % (pol.get("PolicyName"), r["RoleName"], RETIRED))
            for kind, listing, holder, policies in (
                    ("user", "UserDetailList", "UserName", "UserPolicyList"),
                    ("group", "GroupDetailList", "GroupName", "GroupPolicyList")):
                for ident in page.get(listing, []):
                    for pol in ident.get(policies, []):
                        ck.require(not _mentions(pol.get("PolicyDocument")),
                                   "the inline policy %r of %s %s still names %s; the audit is to leave "
                                   "nothing in the account naming that role"
                                   % (pol.get("PolicyName"), kind, ident[holder], RETIRED))
            for pol in page.get("Policies", []):
                for v in pol.get("PolicyVersionList", []):
                    if v.get("IsDefaultVersion"):
                        ck.require(not _mentions(v.get("Document")),
                                   "the customer-managed policy %s still names %s; the audit is to leave "
                                   "nothing in the account naming that role"
                                   % (pol.get("PolicyName"), RETIRED))
    except ClientError as e:
        ck.fail("could not audit the account's IAM configuration: %s" % e.response["Error"]["Code"])


def associated():
    try:
        return gg.get_service_role_for_account().get("roleArn")
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("ResourceNotFoundException", "404", "NotFoundException"):
            return None
        ck.fail("could not read the account's service-role association to confirm the reference is gone: %s"
                % code)

current = associated()
for _ in range(4):
    time.sleep(5)
    again = associated()
    if again == current:
        break
    current = again

if current:
    role_name = current.rsplit("/", 1)[-1]
    ck.require(current != RETIRED_ARN and role_name != RETIRED,
               "the account's service-role association still names the deleted role %s (%s); that is what "
               "a new role of the same name would inherit" % (RETIRED, current))
    try:
        iam.get_role(RoleName=role_name)
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            ck.fail("the association now names %r, which does not exist; swapping one dangling reference "
                    "for another is not a repair" % role_name)
        ck.fail("could not confirm the role named by the association exists: %s"
                % e.response["Error"]["Code"])
    ck.require(_predates_handover(role_name),
               "the association now names %r, a role that was not in this account at hand-over; the task "
               "states no new role is to be created" % role_name)

try:
    iam.get_role(RoleName=RETIRED)
    recreated = True
except ClientError as e:
    if e.response["Error"]["Code"] == "NoSuchEntity":
        recreated = False
    else:
        ck.fail("could not confirm the deleted role stayed deleted: %s" % e.response["Error"]["Code"])
ck.require(not recreated,
           "the role %s was re-created; the decommissioning removed it on purpose and a name that comes "
           "back to life is the hazard, not the repair" % RETIRED)

_keep_unchanged()
_audit_account()

ck.ok("nothing in the account still names %s -- the service-role association reads %s, no IAM policy "
      "document names it, the deleted role is still absent, no new role was created, and %s is untouched"
      % (RETIRED, current or "unset", KEEP))
