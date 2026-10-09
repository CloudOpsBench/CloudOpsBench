#!/usr/bin/env bash
# Teardown — only ever touches vera2- names.
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
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
for S in $(aws ec2 describe-snapshots --region "$REGION" --owner-ids self --filters "Name=tag:Name,Values=vera2-*" \
             --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$S" ] && [ "$S" != "None" ] || continue
  aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$S" >/dev/null 2>&1 || true
done
for V in $(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:Name,Values=vera2-*" \
             --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$V" ] && [ "$V" != "None" ] || continue
  aws ec2 delete-volume --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
done
for R in $(aws iam list-roles --query "Roles[?starts_with(RoleName,'vera2-')].RoleName" --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$R" ] && [ "$R" != "None" ] || continue
  aws iam delete-role --role-name "$R" >/dev/null 2>&1 || true
done
echo "torn down: vera2- AMIs + SageMaker images + snapshots + volumes + role"
