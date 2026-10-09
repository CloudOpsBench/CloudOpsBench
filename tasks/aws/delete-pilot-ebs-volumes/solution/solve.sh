#!/usr/bin/env bash
set -uo pipefail
REGION=us-east-1   # the pilot only ever worked here; pinned so setup, grader and teardown cannot disagree
for R in $(aws rbin list-rules --region "$REGION" --resource-type EBS_VOLUME --query 'Rules[].Identifier' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$R" ] && [ "$R" != "None" ] || continue
  COVERS=$(aws rbin get-rule --region "$REGION" --identifier "$R" \
             --query "ResourceTags[?ResourceTagKey=='Project' && ResourceTagValue=='vera2'] | length(@)" --output text 2>/dev/null || echo 0)
  [ "$COVERS" != "0" ] || continue
  aws rbin delete-rule --region "$REGION" --identifier "$R" >/dev/null 2>&1 || true
done
for V in $(aws ec2 list-volumes-in-recycle-bin --region "$REGION" --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$V" ] && [ "$V" != "None" ] || continue
  aws ec2 restore-volume-from-recycle-bin --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
done
for V in $(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:Project,Values=vera2" "Name=tag:Name,Values=vera2-*" "Name=status,Values=available" \
             --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$V" ] && [ "$V" != "None" ] || continue
  aws ec2 delete-volume --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
done
echo "removed the pilot's Recycle Bin retention rule, restored what it had captured, and deleted the volumes"
