#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"

# 1) AMIs owned by this account and named vera2-*.
for I in $(aws ec2 describe-images --region "$REGION" --owners self --filters "Name=name,Values=vera2-*" \
             --query 'Images[].ImageId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$I" ] && [ "$I" != "None" ] || continue
  aws ec2 deregister-image --region "$REGION" --image-id "$I" >/dev/null 2>&1 || true
done

for I in $(aws sagemaker list-images --region "$REGION" --query "Images[?starts_with(ImageName,'vera2-')].ImageName" \
             --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$I" ] && [ "$I" != "None" ] || continue
  aws sagemaker delete-image --region "$REGION" --image-name "$I" >/dev/null 2>&1 || true
done
for _ in $(seq 1 18); do
  LEFT=$(aws sagemaker list-images --region "$REGION" \
           --query "length(Images[?starts_with(ImageName,'vera2-')])" --output text 2>/dev/null || echo 0)
  [ "$LEFT" = "0" ] && break
  sleep 5
done
echo "deleted vera2- AMIs AND vera2- SageMaker images"
