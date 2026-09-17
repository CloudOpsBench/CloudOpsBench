#!/bin/bash
set -euo pipefail

mkdir -p /logs/verifier
# Avoid a stale JSON reward taking precedence over this task's scalar reward.
rm -f /logs/verifier/reward.json
printf '0\n' > /logs/verifier/reward.txt

status=0
python3 /tests/test_infra.py || status=$?
case "$status" in
  0) printf '1\n' > /logs/verifier/reward.txt ;;
  1) ;; # Semantic failure: retain reward 0.
  *) echo "Verifier evaluation error (exit $status); do not score as a valid trial." >&2
     exit "$status" ;;
esac
