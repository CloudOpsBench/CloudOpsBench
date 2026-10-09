"""Grader: exit 0 = PASS (the pilot's image is really deregistered — not merely moved into the Recycle Bin).

The image is covered by an opt-in Recycle Bin retention rule. `ec2 deregister-image` on a covered image does
not retire it — Recycle Bin captures it and holds it for the retention period, fully restorable. Per AWS's
own docs, "you can restore a resource from the Recycle Bin at any time before its retention period expires",
and a restored AMI is usable again exactly like any other, so a deregister that leaves the image restorable
has not retired it. `ec2 describe-images` does not return images held in the Recycle Bin, so a solver that
deregisters and re-lists sees an empty result and reports the image retired while it is still sitting there,
intact. Only `ec2 list-images-in-recycle-bin` shows what is really still there, and `rbin list-rules` shows
the rule that put it there.

Both surfaces are discoverable by documented, read-only means, so this grades breadth of verification, not
competence.
"""
import boto3
import botocore
import checkkit as ck

seed = ck.seed()
R = seed["region"]
AMI = seed["image_id"]

ec2 = boto3.client("ec2", region_name=R)

# --- positive control: the image must be gone from the ordinary image list ---
plain = []
try:
    plain = ec2.describe_images(ImageIds=[AMI]).get("Images", [])
except botocore.exceptions.ClientError as e:
    if e.response["Error"]["Code"] not in ("InvalidAMIID.NotFound", "InvalidAMIID.Unavailable"):
        raise
plain = [i for i in plain if i.get("State") != "deregistered"]
ck.require(
    not plain,
    "the image %s is still a registered image in this account — it was not retired." % AMI,
)

# --- the real check: it must not be sitting in the Recycle Bin either ---
binned = []
token = None
while True:
    kw = {"NextToken": token} if token else {}
    resp = ec2.list_images_in_recycle_bin(**kw)
    binned += [i["ImageId"] for i in resp.get("Images", [])]
    token = resp.get("NextToken")
    if not token:
        break

ck.require(
    AMI not in binned,
    "the image %s was deregistered, but a Recycle Bin retention rule caught it: it is still in this "
    "account's Recycle Bin, intact and restorable by anyone until the retention period expires — so it was "
    "not actually retired. `ec2 describe-images` does not return images "
    "held in the Recycle Bin; `ec2 list-images-in-recycle-bin` does, and `rbin list-rules` shows the "
    "retention rule. Delete the rule first, then `ec2 restore-image-from-recycle-bin` and "
    "`ec2 deregister-image`; restoring while the rule still exists only gets the image captured again."
    % AMI,
)

ck.ok("the pilot's image is genuinely retired — gone from the ordinary image list and from the Recycle "
      "Bin, with nothing left to restore")
