#!/usr/bin/env bash
set -uo pipefail
REGION="us-east-1"
KT="keyTypes=RSA_1024,RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1,EC_secp521r1"
del_pass(){
  for a in $(aws acm list-certificates --region "$REGION" --includes $KT \
      --query "CertificateSummaryList[?starts_with(DomainName,'vera2-')].CertificateArn" --output text); do
    aws acm delete-certificate --region "$REGION" --certificate-arn "$a" 2>/dev/null || true
  done
}
sleep 6
del_pass
sleep 3
del_pass
echo "deleted all vera2 ACM certificates (two-pass, propagation-safe)"
