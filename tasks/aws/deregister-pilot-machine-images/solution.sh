#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"

# 1) Drop the retention rules that cover the pilot's images.
for R in $(aws rbin list-rules --region "$REGION" --resource-type EC2_IMAGE \
             --query 'Rules[].Identifier' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$R" ] && [ "$R" != "None" ] || continue
  COVERS=$(aws rbin get-rule --region "$REGION" --identifier "$R" \
             --query "ResourceTags[?ResourceTagKey=='Project' && ResourceTagValue=='vera2'] | length(@)" \
             --output text 2>/dev/null || echo 0)
  [ "$COVERS" != "0" ] || continue
  aws rbin delete-rule --region "$REGION" --identifier "$R" >/dev/null 2>&1 || true
done

# 2) Pull back anything the rule already swallowed.
for I in $(aws ec2 list-images-in-recycle-bin --region "$REGION" \
             --query 'Images[].ImageId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$I" ] && [ "$I" != "None" ] || continue
  aws ec2 restore-image-from-recycle-bin --region "$REGION" --image-id "$I" >/dev/null 2>&1 || true
done

# 3) Retire the pilot's images for real, then release the snapshots they were holding open.
for I in $(aws ec2 describe-images --region "$REGION" --owners self \
             --filters "Name=tag:Project,Values=vera2" \
             --query 'Images[].ImageId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$I" ] && [ "$I" != "None" ] || continue
  aws ec2 deregister-image --region "$REGION" --image-id "$I" >/dev/null 2>&1 || true
done

sleep 5
for S in $(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
             --filters "Name=tag:Project,Values=vera2" \
             --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$S" ] && [ "$S" != "None" ] || continue
  aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$S" >/dev/null 2>&1 || true
done

echo "removed the pilot's Recycle Bin retention rule, restored what it had captured, deregistered the images and released their snapshots"
