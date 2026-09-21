#!/bin/bash
# Seeds this task's starting cloud state in the trial's emulator, then hands off to the
# container command. The agent is only let in once /run/cloudopsbench/ready exists (Docker
# HEALTHCHECK and [environment.healthcheck] in task.toml). A failed seed stops the
# container, so the trial is an environment error rather than a scored attempt.
set -uo pipefail

SEED=/opt/cloudopsbench/seed
READY=/run/cloudopsbench/ready

# Explicit exits: `set -e` is ignored inside a function called from an `if` condition.
seed() (
  [ "${AWS_ENDPOINT_URL:-}" = "http://127.0.0.1:5003" ] \
    || { echo "refusing to seed: AWS_ENDPOINT_URL is not the trial emulator" >&2; exit 1; }
  [ "${AWS_REGION:-}" = "us-east-1" ] \
    || { echo "refusing to seed: this task is written for us-east-1" >&2; exit 1; }
  # Explicit dummy identity: never fall back to metadata or mounted AWS profiles.
  export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION="$AWS_REGION"
  unset AWS_SESSION_TOKEN AWS_PROFILE
  cd /workspace || exit 1
  bash "$SEED/setup.sh" || exit 1
  # Setup's notes for the grader ship with the verifier instead; never leave them here.
  rm -f /workspace/seed_state.json
)

if [ ! -f "$READY" ]; then
  # Output goes to the container log only: it names resources the agent must discover.
  if ! seed; then
    echo "cloudopsbench: seeding the starting state failed" >&2
    exit 1
  fi
  find "$SEED" -mindepth 1 -delete
  if [ -n "$(ls -A "$SEED")" ]; then
    echo "cloudopsbench: could not remove the seed" >&2
    exit 1
  fi
  touch "$READY"
fi
[ $# -gt 0 ] || set -- sleep infinity
exec "$@"
