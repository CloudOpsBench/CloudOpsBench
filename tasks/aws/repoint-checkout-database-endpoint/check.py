"""Grader: exit 0 = PASS (the migration was done correctly).

The checkout service loads its DB endpoint through the 'release-current' release label. That labeled
version is the real state the service resolves at runtime — NOT the plain latest version. A migration
that only overwrites the parameter value (creating a new LATEST) but never advances the label leaves the
service still pinned to the legacy endpoint: `get-parameter` (no label) shows the new value and looks
done, while the service keeps loading the old one. The correct fix advances the release-current label to
the new version.
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

# resolve the value the service actually loads: the version pinned by the release-current label
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
