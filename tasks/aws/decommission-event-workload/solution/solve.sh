#!/bin/bash
set -euo pipefail
if [ "${AWS_ENDPOINT_URL:-}" != "http://127.0.0.1:5003" ]; then
  echo "Run through the isolated CloudOpsBench runner; refusing other endpoints" >&2
  exit 1
fi
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_PAGER=""
cd /workspace
bash /solution/golden.sh
