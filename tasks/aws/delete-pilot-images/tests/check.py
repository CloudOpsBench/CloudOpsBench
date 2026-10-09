"""Check that no vera2- image remains in EC2 or SageMaker.

Passes when no vera2- AMI owned by the account is registered and
`sagemaker list-images` returns no vera2- image. Images are enumerated by name,
so only the region is read from seed_state.json.
"""
import time
import boto3
import botocore
import checkkit as ck

seed = ck.seed()
R = seed["region"]

ec2 = boto3.client("ec2", region_name=R)
amis = ec2.describe_images(Owners=["self"], Filters=[{"Name": "name", "Values": ["vera2-*"]}]).get("Images", [])
ck.require(
    not amis,
    "vera2- AMIs are still registered: %s — they were not deregistered."
    % ", ".join(i["ImageId"] for i in amis),
)

# delete-image is asynchronous, so poll while images are still in DELETING.
sm = boto3.client("sagemaker", region_name=R)

def list_sagemaker_images():
    left, tok = [], None
    while True:
        resp = sm.list_images(**({"NextToken": tok} if tok else {}))
        for img in resp.get("Images", []):
            if img["ImageName"].startswith("vera2-"):
                left.append((img["ImageName"], img.get("ImageStatus")))
        tok = resp.get("NextToken")
        if not tok:
            break
    return left

deadline = time.time() + 90
left = list_sagemaker_images()
while left and time.time() < deadline:
    # An image in any state other than DELETING was never deleted; stop waiting.
    if any(st not in ("DELETING",) for _, st in left):
        break
    time.sleep(5)
    left = list_sagemaker_images()

ck.require(
    not left,
    "the AMI side is clear, but the pilot's SageMaker image(s) still exist: %s. SageMaker AI keeps its own "
    "images in a separate control plane: ec2 describe-images does not return them — `sagemaker list-images` "
    "does. Delete each with `sagemaker delete-image` (it is asynchronous — the image must reach the point of "
    "being fully gone, not merely DELETING)."
    % ", ".join("%s(%s)" % (n, s) for n, s in left),
)
ck.ok("no vera2- image remains in either control plane — EC2 and SageMaker are both cleared")
