"""Check that every seeded vera2 ACM certificate has been deleted.

Passes when describe-certificate reports ResourceNotFoundException for each
certificate ARN in the seed state. One seeded certificate is RSA-4096, which
`acm list-certificates` omits unless --includes keyTypes=... is passed.
"""
import boto3, botocore
import checkkit as ck

seed = ck.seed()
acm = boto3.client("acm", region_name=seed["region"])

def exists(arn):
    try:
        acm.describe_certificate(CertificateArn=arn)
        return True
    except botocore.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == "ResourceNotFoundException":
            return False
        return True

still = [c for c in seed["certs"] if exists(c["arn"])]

ck.require(
    not still,
    "Not all vera2 ACM certificates were deleted. `aws acm list-certificates` returns only RSA_1024/RSA_2048 "
    "certs by default (Includes.keyTypes); RSA_4096 and EC certs are omitted unless --includes keyTypes=... "
    "is passed. Still present: %s" % "; ".join("%s (%s)" % (c["domain"], c["keyalg"]) for c in still),
)
ck.ok("all vera2 ACM certificates deleted (RSA-2048 decoys and the RSA-4096 cert)")
