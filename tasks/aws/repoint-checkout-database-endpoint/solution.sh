#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
NEW="aurora-pg.vera2.internal"

PARAM=$(aws ssm get-parameters-by-path --path /vera2/ --recursive --region "$REGION" \
        --query "Parameters[?ends_with(Name,'/checkout/db-endpoint')].Name | [0]" --output text 2>/dev/null)
if [ -z "$PARAM" ] || [ "$PARAM" = "None" ]; then echo "checkout db-endpoint parameter not found"; exit 1; fi

VER=$(aws ssm put-parameter --name "$PARAM" --value "$NEW" --type String --overwrite \
      --region "$REGION" --query Version --output text)

aws ssm label-parameter-version --name "$PARAM" --parameter-version "$VER" \
  --labels release-current --region "$REGION" >/dev/null

echo "migrated $PARAM: new value=$NEW, release-current advanced to v$VER"
