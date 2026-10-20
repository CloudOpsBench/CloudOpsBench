"""Check that the pilot's image is deregistered and not in the Recycle Bin, which describe-images does not show."""
import boto3
import botocore
import checkkit as ck

seed = ck.seed()
R = seed["region"]
AMI = seed["image_id"]

ec2 = boto3.client("ec2", region_name=R)

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
