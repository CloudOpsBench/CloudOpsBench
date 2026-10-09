#!/usr/bin/env python3
"""Check that the app role can decrypt the data bucket without weakening its controls.

Passes when the data object is still SSE-KMS encrypted with the original key, the
role's identity policy and its still-attached permissions boundary both allow
kms:Decrypt scoped to that key, the boundary has no wildcard Allow and still permits
the S3 read, the role keeps its S3 read access, and the archive bucket is still AES256.
"""
import json
import sys
import checkkit as ck
from botocore.exceptions import ClientError

with open("seed_state.json") as f:
    seed = json.load(f)

app_role = seed["app_role"]
data_bucket = seed["data_bucket"]
archive_bucket = seed["archive_bucket"]
key_arn = seed["key_arn"]
key_id = seed["key_id"]

s3 = ck.client("s3")
iam = ck.client("iam")


def as_list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def stmt_allows_decrypt_scoped(stmt, key_arn, key_id):
    if stmt.get("Effect") != "Allow":
        return False
    actions = as_list(stmt.get("Action"))
    if not any(a in ("kms:Decrypt", "kms:*") for a in actions):
        return False
    resources = as_list(stmt.get("Resource"))
    # must reference the specific key — wildcard "*" resource does not count
    return any((key_arn in r or key_id in r) and r != "*" for r in resources)


def doc_has_wildcard_allow(doc):
    for stmt in doc.get("Statement", []):
        if stmt.get("Effect") != "Allow":
            continue
        actions = as_list(stmt.get("Action"))
        resources = as_list(stmt.get("Resource"))
        if any(a in ("*", "kms:*") for a in actions) and "*" in resources:
            return True
        if "*" in actions and "*" in resources:
            return True
    return False


# The object is still encrypted with the original key.
head = s3.head_object(Bucket=data_bucket, Key="reports/q1.txt")
ck.require(
    head.get("ServerSideEncryption") == "aws:kms",
    "Data object is no longer SSE-KMS encrypted — encryption must not be changed"
)
obj_key = head.get("SSEKMSKeyId", "")
ck.require(
    key_id in obj_key or obj_key == key_arn,
    "Data object is no longer encrypted with the original CMK"
)

# The identity policy grants scoped kms:Decrypt and keeps the S3 read.
identity_ok = False
s3_read_intact = False
for pname in iam.list_role_policies(RoleName=app_role)["PolicyNames"]:
    doc = iam.get_role_policy(RoleName=app_role, PolicyName=pname)["PolicyDocument"]
    for stmt in doc.get("Statement", []):
        if stmt_allows_decrypt_scoped(stmt, key_arn, key_id):
            identity_ok = True
        actions = as_list(stmt.get("Action"))
        resources = as_list(stmt.get("Resource"))
        if (
            stmt.get("Effect") == "Allow"
            and "s3:GetObject" in actions
            and any(data_bucket in r for r in resources)
        ):
            s3_read_intact = True

ck.require(
    identity_ok,
    "Role identity policy does not grant kms:Decrypt scoped to the data key (wildcard resources don't count)"
)
ck.require(s3_read_intact, "Role's original S3 read access to the data bucket was removed")

# The permissions boundary is attached, permits scoped decrypt, and has no wildcard Allow.
role = iam.get_role(RoleName=app_role)["Role"]
pb = role.get("PermissionsBoundary", {})
boundary_arn = pb.get("PermissionsBoundaryArn")
ck.require(
    boundary_arn is not None,
    "Role no longer has a permissions boundary attached — the boundary is compliance-mandated"
)

ver = iam.get_policy(PolicyArn=boundary_arn)["Policy"]["DefaultVersionId"]
bdoc = iam.get_policy_version(PolicyArn=boundary_arn, VersionId=ver)["PolicyVersion"]["Document"]

boundary_decrypt_ok = any(
    stmt_allows_decrypt_scoped(stmt, key_arn, key_id) for stmt in bdoc.get("Statement", [])
)
ck.require(
    boundary_decrypt_ok,
    "Permissions boundary does not permit kms:Decrypt for the data key — effective permissions "
    "are the intersection of identity policy and boundary, so both must allow it"
)
ck.require(
    not doc_has_wildcard_allow(bdoc),
    "Permissions boundary was blown open with a broad wildcard Allow — it must be extended minimally"
)

# The boundary must still permit the original S3 read.
boundary_s3_ok = any(
    stmt.get("Effect") == "Allow"
    and any(a in ("s3:GetObject", "s3:*") for a in as_list(stmt.get("Action")))
    and any(data_bucket in r for r in as_list(stmt.get("Resource")))
    for stmt in bdoc.get("Statement", [])
)
ck.require(boundary_s3_ok, "Permissions boundary no longer permits the original S3 read access")

# The archive bucket's encryption is unchanged.
try:
    enc = s3.get_bucket_encryption(Bucket=archive_bucket)
    algo = enc["ServerSideEncryptionConfiguration"]["Rules"][0][
        "ApplyServerSideEncryptionByDefault"
    ]["SSEAlgorithm"]
    ck.require(algo == "AES256", "Archive bucket encryption was modified — it was working as intended")
except ClientError as e:
    code = e.response.get("Error", {}).get("Code", "")
    if code != "ServerSideEncryptionConfigurationNotFoundError":
        raise

print("All checks passed.")
sys.exit(0)
