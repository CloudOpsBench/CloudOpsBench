#!/usr/bin/env bash
# Deletes the vera2 ACM certificates created by setup.
set -uo pipefail
# Delete the certificates recorded in seed_state.json.
python3 - <<'PY' 2>/dev/null || true
import json,boto3
try: s=json.load(open("seed_state.json"))
except Exception: raise SystemExit
acm=boto3.client("acm",region_name=s.get("region","us-east-1"))
for a in s.get("all_arns",[]):
    try: acm.delete_certificate(CertificateArn=a)
    except Exception: pass
PY
# Sweep any remaining vera2- certificates across all key types.
python3 - <<'PY' 2>/dev/null || true
import boto3
acm=boto3.client("acm",region_name="us-east-1")
kt=["RSA_1024","RSA_2048","RSA_3072","RSA_4096","EC_prime256v1","EC_secp384r1","EC_secp521r1"]
try:
    for pg in acm.get_paginator("list_certificates").paginate(Includes={"keyTypes":kt}):
        for c in pg.get("CertificateSummaryList",[]):
            if c.get("DomainName","").startswith("vera2-"):
                try: acm.delete_certificate(CertificateArn=c["CertificateArn"])
                except Exception: pass
except Exception: pass
PY
exit 0
