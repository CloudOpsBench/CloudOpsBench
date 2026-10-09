#!/usr/bin/env bash
# Creates a Recycle Bin retention rule for EBS volumes tagged Project=vera2,
# confirms with a canary volume that the rule is enforcing, then creates the
# pilot volume. The seeded state is recorded in seed_state.json for the checker.
set -euo pipefail
REGION=us-east-1   # the pilot only ever worked here; pinned so setup, grader and teardown cannot disagree
SUF="$(date +%s | tail -c 5)${RANDOM}"
AZ=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneName' --output text)

mkvol() {  # $1 = name suffix
  aws ec2 create-volume --region "$REGION" --availability-zone "$AZ" --size 1 --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=vera2-${SUF}-$1},{Key=Project,Value=vera2}]" \
    --query VolumeId --output text
}

wait_vol() {  # $1 = volume id
  local s
  for _ in $(seq 1 40); do
    s=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
          --query 'Volumes[0].State' --output text 2>/dev/null || echo pending)
    [ "$s" = "available" ] && return 0
    sleep 3
  done
  return 1
}

RULE=$(aws rbin create-rule --region "$REGION" \
        --retention-period RetentionPeriodValue=7,RetentionPeriodUnit=DAYS \
        --resource-type EBS_VOLUME \
        --resource-tags ResourceTagKey=Project,ResourceTagValue=vera2 \
        --description "vera2-${SUF} pilot volume retention" \
        --query Identifier --output text)
for _ in $(seq 1 20); do
  ST=$(aws rbin get-rule --region "$REGION" --identifier "$RULE" --query Status --output text 2>/dev/null || echo pending)
  [ "$ST" = "available" ] && break; sleep 3
done
[ "$ST" = "available" ] || { echo "FATAL: recycle-bin rule never became available (last=$ST)"; exit 1; }

MINE=$(mktemp)
# Retry until a wall-clock deadline rather than a fixed attempt count, because one
# create/delete/poll round can take over a minute and setup has a 10-minute limit.
PROVE_DEADLINE=$(( $(date +%s) + 330 ))
prove_enforcing() {  # echoes the captured volume id on success, else returns 1
  local i j C IN
  i=0
  while [ "$(date +%s)" -lt "$PROVE_DEADLINE" ]; do
    i=$((i+1))
    C=$(mkvol "canary${i}") || continue
    echo "$C" >> "$MINE"
    wait_vol "$C" || continue
    aws ec2 delete-volume --region "$REGION" --volume-id "$C" >/dev/null 2>&1 || continue
    for j in $(seq 1 4); do
      IN=$(aws ec2 list-volumes-in-recycle-bin --region "$REGION" \
            --query "Volumes[?VolumeId=='${C}'] | length(@)" --output text 2>/dev/null || echo 0)
      [ "$IN" = "1" ] && { echo "$C"; return 0; }
      sleep 4
    done
  done
  return 1
}
CANARY=$(prove_enforcing) || { echo "FATAL: retention rule reported available but never captured the canary — not enforcing"; exit 1; }
aws ec2 restore-volume-from-recycle-bin --region "$REGION" --volume-id "$CANARY" >/dev/null 2>&1 || true
aws ec2 delete-tags --region "$REGION" --resources "$CANARY" --tags Key=Project >/dev/null 2>&1 || true
sleep 3
aws ec2 delete-volume --region "$REGION" --volume-id "$CANARY" >/dev/null 2>&1 || true
# Empty the Recycle Bin, then verify that none of this run's canaries remain in it.
for _ in $(seq 1 8); do
  LEFT=$(aws ec2 list-volumes-in-recycle-bin --region "$REGION" --query 'length(Volumes)' --output text 2>/dev/null || echo 0)
  [ "$LEFT" = "0" ] && break
  for V in $(aws ec2 list-volumes-in-recycle-bin --region "$REGION" --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n'); do
    [ -n "$V" ] && [ "$V" != "None" ] || continue
    aws ec2 restore-volume-from-recycle-bin --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
    aws ec2 delete-tags --region "$REGION" --resources "$V" --tags Key=Project >/dev/null 2>&1 || true
    aws ec2 delete-volume --region "$REGION" --volume-id "$V" >/dev/null 2>&1 || true
  done
  sleep 4
done

BIN=$(aws ec2 list-volumes-in-recycle-bin --region "$REGION" --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n')
STUCK=""
while read -r C; do
  [ -n "$C" ] || continue
  case "
$BIN
" in *"
$C
"*) STUCK="$STUCK $C" ;; esac
done < "$MINE"
rm -f "$MINE"
[ -z "$STUCK" ] || { echo "FATAL: this run's own canary is still in the Recycle Bin:$STUCK — that would teach the solver the answer"; exit 1; }
LEFT=$(aws ec2 list-volumes-in-recycle-bin --region "$REGION" --query 'length(Volumes)' --output text 2>/dev/null || echo 0)
[ "$LEFT" = "0" ] || echo "note: $LEFT unrelated volume(s) from an earlier run remain in the bin; they are not removable and expire on their own"

# The pilot volume: an available EBS volume tagged Project=vera2, covered by the rule.
VOL=$(mkvol data)
wait_vol "$VOL" || { echo "FATAL: volume $VOL never became available"; exit 1; }

python3 - "$REGION" "$VOL" "$RULE" <<'PY'
import json, sys
json.dump({"region": sys.argv[1], "volume_id": sys.argv[2], "rbin_rule": sys.argv[3]},
          open("seed_state.json", "w"), indent=2)
PY
echo "seeded volume $VOL (Project=vera2) + Recycle Bin retention rule $RULE, PROVEN enforcing by canary"
