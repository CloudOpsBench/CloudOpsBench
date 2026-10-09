#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SUF="$(date +%s | tail -c 5)${RANDOM}"

AZ=$(aws ec2 describe-availability-zones --region "$REGION" \
      --query 'AvailabilityZones[0].ZoneName' --output text)

VOL=$(aws ec2 create-volume --region "$REGION" --availability-zone "$AZ" \
        --size 1 --volume-type gp3 \
        --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=vera2-${SUF}-build},{Key=Project,Value=vera2}]" \
        --query VolumeId --output text)
aws ec2 wait volume-available --region "$REGION" --volume-ids "$VOL"

SNAP=$(aws ec2 create-snapshot --region "$REGION" --volume-id "$VOL" \
        --description "vera2-${SUF} image base" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=vera2-${SUF}-base}]" \
        --query SnapshotId --output text)
aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$SNAP"
aws ec2 delete-volume --region "$REGION" --volume-id "$VOL" >/dev/null

RULE=$(aws rbin create-rule --region "$REGION" \
        --retention-period RetentionPeriodValue=7,RetentionPeriodUnit=DAYS \
        --resource-type EC2_IMAGE \
        --resource-tags ResourceTagKey=Project,ResourceTagValue=vera2 \
        --description "vera2-${SUF} pilot image retention" \
        --query Identifier --output text)

for _ in $(seq 1 20); do
  ST=$(aws rbin get-rule --region "$REGION" --identifier "$RULE" --query Status --output text 2>/dev/null || echo pending)
  [ "$ST" = "available" ] && break
  sleep 3
done
[ "$ST" = "available" ] || { echo "FATAL: recycle-bin rule never became available (last=$ST)"; exit 1; }

register_ami() {  # $1 = name suffix
  aws ec2 register-image --region "$REGION" \
    --name "vera2-${SUF}-$1" --description "vera2-${SUF} pilot $1 image" \
    --architecture x86_64 --virtualization-type hvm --ena-support \
    --root-device-name /dev/xvda \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=${SNAP},VolumeSize=1,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=vera2-${SUF}-$1},{Key=Project,Value=vera2}]" \
    --query ImageId --output text
}
wait_ami() {
  for _ in $(seq 1 30); do
    S=$(aws ec2 describe-images --region "$REGION" --image-ids "$1" --query 'Images[0].State' --output text 2>/dev/null || echo pending)
    [ "$S" = "available" ] && return 0
    sleep 3
  done
  return 1
}

prove_enforcing() {  # echoes the captured image id on success, else returns 1
  local i j C IN
  for i in $(seq 1 12); do
    C=$(register_ami "canary${i}") || continue
    wait_ami "$C" || continue
    aws ec2 deregister-image --region "$REGION" --image-id "$C" >/dev/null 2>&1 || continue
    for j in $(seq 1 3); do
      IN=$(aws ec2 list-images-in-recycle-bin --region "$REGION" \
            --query "Images[?ImageId=='${C}'] | length(@)" --output text 2>/dev/null || echo 0)
      [ "$IN" = "1" ] && { echo "$C"; return 0; }
      sleep 5
    done
  done
  return 1
}
CANARY=$(prove_enforcing) || { echo "FATAL: retention rule reported available but never captured the canary — not enforcing"; exit 1; }
aws ec2 restore-image-from-recycle-bin --region "$REGION" --image-id "$CANARY" >/dev/null 2>&1 || true
aws ec2 delete-tags --region "$REGION" --resources "$CANARY" --tags Key=Project >/dev/null 2>&1 || true
sleep 3
aws ec2 deregister-image --region "$REGION" --image-id "$CANARY" >/dev/null 2>&1 || true
# defensively purge anything the bin may still hold, then require it empty (the solver must learn nothing here)
LEFT=0
for _ in $(seq 1 8); do
  LEFT=$(aws ec2 list-images-in-recycle-bin --region "$REGION" --query 'length(Images)' --output text 2>/dev/null || echo 0)
  [ "$LEFT" = "0" ] && break
  for I in $(aws ec2 list-images-in-recycle-bin --region "$REGION" --query 'Images[].ImageId' --output text 2>/dev/null | tr '\t' '\n'); do
    [ -n "$I" ] && [ "$I" != "None" ] || continue
    aws ec2 restore-image-from-recycle-bin --region "$REGION" --image-id "$I" >/dev/null 2>&1 || true
    aws ec2 delete-tags --region "$REGION" --resources "$I" --tags Key=Project >/dev/null 2>&1 || true
    sleep 2   # let the tag removal land, or the rule captures the image straight back into the bin
    aws ec2 deregister-image --region "$REGION" --image-id "$I" >/dev/null 2>&1 || true
  done
  sleep 4
done
# The loop above samples the bin BEFORE each cleanup pass, so $LEFT still holds the count from the
# start of the final pass. Re-read it here or a bin the last pass just emptied fails setup.
LEFT=$(aws ec2 list-images-in-recycle-bin --region "$REGION" --query 'length(Images)' --output text 2>/dev/null || echo 0)
[ "$LEFT" = "0" ] || { echo "FATAL: canary left $LEFT image(s) in the bin — that would teach the solver the answer"; exit 1; }

AMI=$(register_ami appliance)
wait_ami "$AMI" || { echo "FATAL: AMI never became available"; exit 1; }

python3 - "$REGION" "$AMI" "$SNAP" "$RULE" <<'PY'
import json, sys
json.dump({"region": sys.argv[1], "image_id": sys.argv[2], "snapshot_id": sys.argv[3],
           "rbin_rule": sys.argv[4]}, open("seed_state.json", "w"), indent=2)
PY
echo "seeded AMI $AMI (Project=vera2) + Recycle Bin retention rule $RULE, PROVEN enforcing by canary"
