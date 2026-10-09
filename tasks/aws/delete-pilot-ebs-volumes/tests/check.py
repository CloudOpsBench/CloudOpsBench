"""Check that the pilot's EBS volume is deleted and not held in the Recycle Bin.

Passes when the seeded volume is absent from `ec2 describe-volumes` and from
`ec2 list-volumes-in-recycle-bin`. The Recycle Bin is polled for longer while a retention
rule covering Project=vera2 still exists, because capture is not immediate.
"""
import time

import boto3
import botocore
import checkkit as ck

seed = ck.seed()
R = seed["region"]
VOL = seed["volume_id"]

ec2 = boto3.client("ec2", region_name=R)

# The volume must be gone from the ordinary volume list.
plain = []
try:
    plain = ec2.describe_volumes(VolumeIds=[VOL]).get("Volumes", [])
except botocore.exceptions.ClientError as e:
    if e.response["Error"]["Code"] not in ("InvalidVolume.NotFound", "InvalidVolumeID.NotFound"):
        raise
plain = [v for v in plain if v.get("State") != "deleting"]
ck.require(
    not plain,
    "the volume %s is still an ordinary volume in this account — it was not deleted." % VOL,
)

# The volume must not be held in the Recycle Bin either.
rbin = boto3.client("rbin", region_name=R)
covering = 0
try:
    for r in rbin.list_rules(ResourceType="EBS_VOLUME").get("Rules", []):
        d = rbin.get_rule(Identifier=r["Identifier"])
        for t in d.get("ResourceTags", []):
            if t.get("ResourceTagKey") == "Project" and t.get("ResourceTagValue") == "vera2":
                covering += 1
except botocore.exceptions.ClientError:
    pass


def _binned():
    ids, token = [], None
    while True:
        kw = {"NextToken": token} if token else {}
        resp = ec2.list_volumes_in_recycle_bin(**kw)
        ids += [v["VolumeId"] for v in resp.get("Volumes", [])]
        token = resp.get("NextToken")
        if not token:
            return ids


attempts = 15 if covering else 4  # ~105s while a capture is still plausible, ~21s once the rule is gone
captured = False
for _i in range(attempts):
    if VOL in _binned():
        captured = True
        break
    if _i + 1 < attempts:
        time.sleep(7)

ck.require(
    not captured,
    "the delete call succeeded, but a Recycle Bin retention rule caught volume %s: it is sitting in this "
    "account's Recycle Bin, intact and restorable by anyone until the retention period expires, and still "
    "billed at the normal volume rate — so it was not actually deleted. `ec2 describe-volumes` does not "
    "return volumes held in the Recycle Bin; `ec2 list-volumes-in-recycle-bin` does, and `rbin list-rules` "
    "shows the retention rule. Delete the rule first, then `ec2 restore-volume-from-recycle-bin` and "
    "`ec2 delete-volume`; restoring while the rule still exists only gets the volume captured again." % VOL,
)

ck.ok("the pilot's volume is genuinely deleted — gone from the ordinary volume list and from the Recycle "
      "Bin, with nothing left to restore")
