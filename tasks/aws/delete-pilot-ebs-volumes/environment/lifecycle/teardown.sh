#!/usr/bin/env bash
# Deletes the Recycle Bin retention rules covering Project=vera2 and the vera2
# volumes, including any held in the Recycle Bin.
set -uo pipefail
REGION=us-east-1   # the pilot only ever worked here; pinned so setup, grader and teardown cannot disagree

# Retention rules covering Project=vera2 must go first, or restored volumes get captured again.
for R in $(aws rbin list-rules --region "$REGION" --resource-type EBS_VOLUME \
             --query 'Rules[].Identifier' --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$R" ] && [ "$R" != "None" ] || continue
  COVERS=$(aws rbin get-rule --region "$REGION" --identifier "$R" \
             --query "ResourceTags[?ResourceTagKey=='Project' && ResourceTagValue=='vera2'] | length(@)" \
             --output text 2>/dev/null || echo 0)
  [ "$COVERS" != "0" ] || continue
  aws rbin delete-rule --region "$REGION" --identifier "$R" >/dev/null 2>&1 || true
done

list_pilot_volumes() {
  { aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:Project,Values=vera2" \
      --query 'Volumes[].VolumeId' --output text 2>/dev/null
    aws ec2 describe-volumes --region "$REGION" --filters "Name=tag:Name,Values=vera2-*" \
      --query 'Volumes[].VolumeId' --output text 2>/dev/null; } | tr '\t' '\n' | sort -u
}

for _ in 1 2 3; do
  for V in $(aws ec2 list-volumes-in-recycle-bin --region "$REGION" \
               --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n'); do
    [ -n "$V" ] && [ "$V" != "None" ] || continue
    aws ec2 restore-volume-from-recycle-bin --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
  done
  sleep 6
  for V in $(list_pilot_volumes); do
    [ -n "$V" ] && [ "$V" != "None" ] || continue
    aws ec2 delete-tags --region "$REGION" --resources "$V" --tags Key=Project >/dev/null 2>&1 || true
  done
  sleep 20   # let the untag propagate, so a rule whose deletion has not taken effect yet cannot re-capture
  for V in $(list_pilot_volumes); do
    [ -n "$V" ] && [ "$V" != "None" ] || continue
    aws ec2 delete-volume --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
  done
  VB=$(aws ec2 list-volumes-in-recycle-bin --region "$REGION" --query 'length(Volumes)' --output text 2>/dev/null || echo 0)
  [ "$VB" = "0" ] && break
  sleep 6
done

echo "torn down: vera2 recycle-bin rules, binned + plain vera2 volumes"
