#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

python3 "$(dirname "$0")/assets/seed.py"
