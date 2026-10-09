#!/usr/bin/env bash
# Creates two SQS queues and one MediaConvert queue named vera2-*, and writes
# the region to seed_state.json.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
SUF="${RANDOM}${RANDOM}"
EP=$(aws mediaconvert describe-endpoints --region "$REGION" --query 'Endpoints[0].Url' --output text)

aws sqs create-queue --queue-name "vera2-ingest-${SUF}" --region "$REGION" >/dev/null
aws sqs create-queue --queue-name "vera2-worker-${SUF}" --region "$REGION" >/dev/null
for i in $(seq 1 24); do
  n=$(aws sqs list-queues --queue-name-prefix vera2- --region "$REGION" --query 'length(QueueUrls)' --output text 2>/dev/null || echo None)
  [ "$n" = "2" ] && break
  sleep 5
done

aws mediaconvert --endpoint-url "$EP" --region "$REGION" create-queue --name "vera2-transcode-${SUF}" >/dev/null

python3 - "$REGION" <<'PY'
import json,sys
json.dump({"region":sys.argv[1]},open("seed_state.json","w"),indent=2)
PY
echo "seeded 2 vera2 SQS queues (decoy, visible) + 1 vera2 MediaConvert queue (hidden) in $REGION"
