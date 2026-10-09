#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SUF="${RANDOM}${RANDOM}"
PARAM="/vera2/${SUF}/checkout/db-endpoint"

# clean any stale copy of this exact name
aws ssm delete-parameter --name "$PARAM" --region "$REGION" >/dev/null 2>&1 || true

aws ssm put-parameter --name "$PARAM" --type String \
  --value "legacy-oracle-01.vera2.internal" --region "$REGION" >/dev/null

aws ssm label-parameter-version --name "$PARAM" --parameter-version 1 \
  --labels release-current --region "$REGION" >/dev/null

python3 - "$REGION" "$PARAM" <<'PY'
import json, sys
json.dump(
    {"region": sys.argv[1], "param": sys.argv[2],
     "label": "release-current", "new_value": "aurora-pg.vera2.internal",
     "old_value": "legacy-oracle-01.vera2.internal"},
    open("seed_state.json", "w"), indent=2)
PY
echo "seeded SSM param $PARAM (v1=legacy; label release-current -> v1)"
