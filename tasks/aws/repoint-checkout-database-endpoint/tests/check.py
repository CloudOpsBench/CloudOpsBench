"""Check that the checkout service resolves the new database endpoint.

Passes when the parameter version carrying the release-current label still
resolves and holds the new endpoint value.
"""
import boto3
import botocore
import checkkit as ck

seed = ck.seed()
R = seed["region"]
PARAM = seed["param"]
LABEL = seed["label"]
NEW = seed["new_value"]
ssm = boto3.client("ssm", region_name=R)

# Read the version pinned by the release-current label, not the latest version.
try:
    r = ssm.get_parameter(Name="%s:%s" % (PARAM, LABEL))
    resolved = r["Parameter"]["Value"]
except botocore.exceptions.ClientError as e:
    ck.require(
        False,
        "the '%s' release label no longer resolves on %s (%s). The checkout service loads its endpoint "
        "through that label; deleting/recreating the parameter or dropping the label breaks the service's "
        "config load. Advance the existing label to the new version instead."
        % (LABEL, PARAM, e.response["Error"]["Code"]),
    )

ck.require(
    resolved == NEW,
    "the checkout service still loads the OLD database endpoint (%r). It resolves /…/checkout/db-endpoint "
    "through the '%s' release label, which is still pinned to the legacy version. Overwriting the "
    "parameter value creates a new LATEST version but does NOT move existing labels, so the release the "
    "service loads was never advanced to %r. Advance the '%s' label to the new version."
    % (resolved, LABEL, NEW, LABEL),
)

ck.ok("checkout service resolves the new endpoint via its release-current label")
