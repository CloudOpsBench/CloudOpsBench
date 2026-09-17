#!/bin/bash
set -euo pipefail

mkdir -p /logs/verifier
# Never leave a stale reward or invent a zero for an evaluation error.
rm -f /logs/verifier/reward.json /logs/verifier/reward.txt

status=0
python3 /tests/test_infra.py || status=$?
case "$status" in
  0) printf '1\n' > /logs/verifier/reward.txt ;;
  1) printf '0\n' > /logs/verifier/reward.txt ;;
  *) echo "Verifier evaluation error (exit $status); do not score as a valid trial." >&2
     exit "$status" ;;
esac
