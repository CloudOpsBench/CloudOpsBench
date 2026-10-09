#!/usr/bin/env bash
set -uo pipefail
python3 - <<'PY' 2>/dev/null || true
import json,boto3
try:
    s=json.load(open("seed_state.json"))
except Exception:
    raise SystemExit
cw=boto3.client("cloudwatch",region_name=s["region"])
try: cw.delete_alarms(AlarmNames=s["composite_alarms"])
except Exception: pass
try: cw.delete_alarms(AlarmNames=s["metric_alarms"])
except Exception: pass
PY
exit 0
