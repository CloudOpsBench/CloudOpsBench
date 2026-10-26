#!/usr/bin/env bash
# Creates two vera2-* metric alarms and one vera2-* composite alarm, all with actions
# enabled, and records their names in seed_state.json.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SUF="${RANDOM}${RANDOM}"
AA="vera2-cpu-high-${SUF}"
AB="vera2-mem-high-${SUF}"
AC="vera2-service-degraded-${SUF}"
mkalarm(){ aws cloudwatch put-metric-alarm --alarm-name "$1" --namespace vera2/app --metric-name "$2" \
  --statistic Average --period 300 --evaluation-periods 1 --threshold 80 --comparison-operator GreaterThanThreshold \
  --actions-enabled --region "$REGION"; }
mkalarm "$AA" CPUUtilization
mkalarm "$AB" MemUtilization
aws cloudwatch put-composite-alarm --alarm-name "$AC" \
  --alarm-rule "ALARM(\"$AA\") OR ALARM(\"$AB\")" --actions-enabled --region "$REGION"
python3 - "$REGION" "$AA" "$AB" "$AC" <<'PY'
import json,sys
r,aa,ab,ac=sys.argv[1:]
json.dump({"region":r,"metric_alarms":[aa,ab],"composite_alarms":[ac]},open("seed_state.json","w"),indent=2)
PY
echo "seeded: metric alarms $AA,$AB + composite alarm $AC — all actions ENABLED"
