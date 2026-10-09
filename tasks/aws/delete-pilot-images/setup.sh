#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SUF="$(date +%s | tail -c 5)${RANDOM}"
ACCT=$(aws sts get-caller-identity --query Account --output text)

# 1) The obvious image: an AMI. `ec2 describe-images` returns it. Positive control.
VOL=$(aws ec2 create-volume --region "$REGION" --availability-zone "${REGION}a" --size 1 --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=vera2-${SUF}-vol}]" \
  --query VolumeId --output text)
aws ec2 wait volume-available --region "$REGION" --volume-ids "$VOL"
SNAP=$(aws ec2 create-snapshot --region "$REGION" --volume-id "$VOL" --description "vera2-${SUF}-base" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=vera2-${SUF}-base}]" \
  --query SnapshotId --output text)
aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$SNAP"
AMI=$(aws ec2 register-image --region "$REGION" --name "vera2-${SUF}-base" --root-device-name /dev/xvda \
  --architecture x86_64 --virtualization-type hvm --ena-support \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=${SNAP},VolumeSize=1,VolumeType=gp3}" \
  --query ImageId --output text)

ROLE="vera2-${SUF}-sm"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sagemaker.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
sleep 12  # IAM propagation: SageMaker validates the role at create time
SM_IMAGE="vera2-${SUF}-lab"
for _ in $(seq 1 6); do
  aws sagemaker create-image --region "$REGION" --image-name "$SM_IMAGE" \
    --role-arn "arn:aws:iam::${ACCT}:role/${ROLE}" >/dev/null 2>&1 && break
  sleep 8
done
aws sagemaker describe-image --region "$REGION" --image-name "$SM_IMAGE" >/dev/null 2>&1 \
  || { echo "FATAL: sagemaker image not created"; exit 1; }

python3 - "$REGION" "$AMI" "$SNAP" "$VOL" "$SM_IMAGE" <<'PY'
import json, sys
json.dump({"region": sys.argv[1], "ami": sys.argv[2], "ebs_snapshot": sys.argv[3], "ebs_volume": sys.argv[4],
           "sagemaker_image": sys.argv[5]}, open("seed_state.json", "w"), indent=2)
PY
echo "seeded AMI $AMI (visible to ec2 describe-images) + SageMaker image $SM_IMAGE (own control plane)"
