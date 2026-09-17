"""S3 final-state checks. Connection integration is intentionally blocked.

The client methods below are standard AWS S3 / boto3 concepts, not an invented
emulator SDK. No SDK is imported or instantiated until integration is defined.
"""

import sys

BUCKET = "cloudopsbench-data"
PUBLIC_ACCESS_FLAGS = (
    "BlockPublicAcls",
    "IgnorePublicAcls",
    "BlockPublicPolicy",
    "RestrictPublicBuckets",
)


class IntegrationError(RuntimeError):
    """Setup, connection, or verifier failures: not a valid scored trial."""


def connect_s3():
    # TODO: construct a standard AWS SDK S3 client only after the emulator
    # contract specifies endpoint, TLS, region, addressing, emulator-only
    # identity, and the trial scope. Disable all real-cloud/metadata fallback.
    # Configuration must be trusted and independent of agent-controlled files.
    # TODO: pin/install the SDK in the verifier environment and enforce egress.
    raise IntegrationError("TODO: trusted emulator S3 connection is not implemented")


def require(condition, message):
    # Explicit checks remain active even when Python is run with optimization.
    if not condition:
        raise AssertionError(message)


def verify_bucket(s3):
    """Read resulting cloud state; accept equivalent Terraform implementations."""
    # TODO: classify standard missing-bucket/configuration API errors as semantic
    # failures once actual emulator error fidelity is known. Other API failures
    # remain evaluation errors; do not swallow connection/auth failures as passes.
    s3.head_bucket(Bucket=BUCKET)
    versioning = s3.get_bucket_versioning(Bucket=BUCKET)
    require(versioning.get("Status") == "Enabled", "Versioning must be Enabled")

    block = s3.get_public_access_block(Bucket=BUCKET).get(
        "PublicAccessBlockConfiguration", {}
    )
    for flag in PUBLIC_ACCESS_FLAGS:
        require(block.get(flag) is True, f"Public access flag {flag} must be true")

    encryption = s3.get_bucket_encryption(Bucket=BUCKET).get(
        "ServerSideEncryptionConfiguration", {}
    )
    rules = encryption.get("Rules", [])
    require(bool(rules), "Default server-side encryption is required")
    for rule in rules:
        algorithm = rule.get("ApplyServerSideEncryptionByDefault", {}).get("SSEAlgorithm")
        require(
            algorithm in {"AES256", "aws:kms", "aws:kms:dsse"},
            "Default encryption must use a supported SSE algorithm",
        )

    tags = {
        tag["Key"]: tag["Value"]
        for tag in s3.get_bucket_tagging(Bucket=BUCKET).get("TagSet", [])
    }
    require(tags.get("Environment") == "production", "Environment tag must be production")


def main():
    try:
        verify_bucket(connect_s3())
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"EVALUATION ERROR: {error}", file=sys.stderr)
        return 2
    print("PASS: all required S3 state checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
