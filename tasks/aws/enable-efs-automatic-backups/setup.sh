#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"; ALT="us-west-2"; SUF="${RANDOM}${RANDOM}"
mk(){ local tok="$1" reg="$2"
  local id=$(aws efs create-file-system --creation-token "$tok" --region "$reg" \
    --tags Key=Project,Value=vera2 Key=Name,Value="$tok" --query 'FileSystemId' --output text)
  for i in $(seq 1 30); do
    st=$(aws efs describe-file-systems --file-system-id "$id" --region "$reg" --query 'FileSystems[0].LifeCycleState' --output text 2>/dev/null || echo creating)
    [ "$st" = "available" ] && break; sleep 3
  done
  aws efs put-backup-policy --file-system-id "$id" --backup-policy Status=DISABLED --region "$reg" >/dev/null 2>&1 || true
  echo "$id"
}
F1=$(mk "vera2-fs-${SUF}-a" "$REGION"); F2=$(mk "vera2-fs-${SUF}-b" "$REGION"); F3=$(mk "vera2-fs-${SUF}-w" "$ALT")
python3 - "$REGION" "$ALT" "$F1" "$F2" "$F3" <<'PY'
import json,sys
r,a,x,y,z=sys.argv[1:]
json.dump({"region":r,"alt_region":a,"filesystems":{r:[x,y],a:[z]}},open("seed_state.json","w"),indent=2)
PY
echo "seeded EFS filesystems in $REGION + $ALT (backup DISABLED)"
