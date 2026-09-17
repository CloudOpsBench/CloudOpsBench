#!/bin/bash
set -euo pipefail
mkdir -p /logs/verifier
rm -f /logs/verifier/reward.txt /logs/verifier/reward.json
status=0
python3 -I /tests/test_infra.py || status=$?
case "$status" in
  0) printf '1\n' > /logs/verifier/reward.txt ;;
  1) printf '0\n' > /logs/verifier/reward.txt ;;
  *) echo "Verifier error; no reward written" >&2; exit "$status" ;;
esac
