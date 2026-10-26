#!/usr/bin/env bash
# Runs assets/seed.py, which creates the metering export pipeline.
set -euo pipefail
export MSYS_NO_PATHCONV=1

python3 "$(dirname "$0")/assets/seed.py"
