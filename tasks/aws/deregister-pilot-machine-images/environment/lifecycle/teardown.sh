#!/usr/bin/env bash
# Teardown — only ever touches the pilot's own Project=vera2 / vera2- resources.
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"

for T in EC2_IMAGE EBS_SNAPSHOT; do
  for R in $(aws rbin list-rules --region "$REGION" --resource-type "$T" \
               --query 'Rules[].Identifier' --output text 2>/dev/null | tr '\t' '\n'); do
    [ -n "$R" ] && [ "$R" != "None" ] || continue
    COVERS=$(aws rbin get-rule --region "$REGION" --identifier "$R" \
               --query "ResourceTags[?ResourceTagKey=='Project' && ResourceTagValue=='vera2'] | length(@)" \
               --output text 2>/dev/null || echo 0)
    [ "$COVERS" != "0" ] || continue
    aws rbin delete-rule --region "$REGION" --identifier "$R" >/dev/null 2>&1 || true
  done
done

for I in $(aws ec2 list-images-in-recycle-bin --region "$REGION" \
             --query 'Images[].ImageId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$I" ] && [ "$I" != "None" ] || continue
  aws ec2 restore-image-from-recycle-bin --region "$REGION" --image-id "$I" >/dev/null 2>&1 || true
done

for I in $(aws ec2 describe-images --region "$REGION" --owners self \
             --filters "Name=tag:Project,Values=vera2" \
             --query 'Images[].ImageId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$I" ] && [ "$I" != "None" ] || continue
  aws ec2 deregister-image --region "$REGION" --image-id "$I" >/dev/null 2>&1 || true
done

sleep 5
for S in $(aws ec2 list-snapshots-in-recycle-bin --region "$REGION" \
             --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$S" ] && [ "$S" != "None" ] || continue
  aws ec2 restore-snapshot-from-recycle-bin --region "$REGION" --snapshot-id "$S" >/dev/null 2>&1 || true
done

for S in $(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
             --filters "Name=tag:Project,Values=vera2" \
             --query 'Snapshots[].SnapshotId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$S" ] && [ "$S" != "None" ] || continue
  aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$S" >/dev/null 2>&1 || true
done

for V in $(aws ec2 describe-volumes --region "$REGION" \
             --filters "Name=tag:Project,Values=vera2" "Name=status,Values=available" \
             --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$V" ] && [ "$V" != "None" ] || continue
  aws ec2 delete-volume --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
done

echo "torn down: vera2 recycle-bin rules, binned + registered vera2 images, vera2 snapshots, vera2 volumes"
