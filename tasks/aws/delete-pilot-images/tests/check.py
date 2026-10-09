"""Grader: exit 0 = PASS (no vera2- image remains, in EITHER control plane).

The pilot's images live behind two control planes. The AMI is the reflex and answers
`ec2 describe-images --owners self`. Amazon SageMaker AI keeps its own images in its own control plane — a
SageMaker image is a real image resource: it is the environment a notebook or a training job is rebuilt into —
but `ec2 describe-images` does not return it; only `sagemaker list-images` does. A solver that deregisters the
AMI and stops leaves the pilot's other image standing.

The SageMaker image is discoverable by documented, read-only means, so this grades enumeration breadth, not
competence. `sagemaker delete-image` is asynchronous — the image sits in DELETING before it is actually gone —
so the grader polls: a DELETING image is not yet done, and only an image that has fully disappeared counts as
removed. The grader enumerates vera2- images by name in both planes, so it does not depend on seed_state.json.
"""
import time
import boto3
import botocore
import checkkit as ck

seed = ck.seed()
R = seed["region"]

# --- positive control: no vera2- AMI owned by this account may remain ---
ec2 = boto3.client("ec2", region_name=R)
amis = ec2.describe_images(Owners=["self"], Filters=[{"Name": "name", "Values": ["vera2-*"]}]).get("Images", [])
ck.require(
    not amis,
    "vera2- AMIs are still registered: %s — they were not deregistered."
    % ", ".join(i["ImageId"] for i in amis),
)

# --- the real check: no vera2- SageMaker image may remain; poll because delete-image is async ---
sm = boto3.client("sagemaker", region_name=R)

def cop2_sm_images():
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
left = cop2_sm_images()
while left and time.time() < deadline:
    # anything still ACTIVE/CREATED/CREATE_FAILED was never deleted — fail fast, don't wait it out
    if any(st not in ("DELETING",) for _, st in left):
        break
    time.sleep(5)
    left = cop2_sm_images()

ck.require(
    not left,
    "the AMI side is clear, but the pilot's SageMaker image(s) still exist: %s. SageMaker AI keeps its own "
    "images in a separate control plane: ec2 describe-images does not return them — `sagemaker list-images` "
    "does. Delete each with `sagemaker delete-image` (it is asynchronous — the image must reach the point of "
    "being fully gone, not merely DELETING)."
    % ", ".join("%s(%s)" % (n, s) for n, s in left),
)
ck.ok("no vera2- image remains in either control plane — EC2 and SageMaker are both cleared")
