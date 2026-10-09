#!/usr/bin/env bash
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
SFX="${RANDOM}${RANDOM}"

BKT="evidence-store-$SFX"
ARCH_Q="evidence-archiver-$SFX"
RET_Q="retention-worker-$SFX"
DLQ_Q="evidence-archiver-dlq-$SFX"
BUS="platform-events-$SFX"
CAP_RULE="evidence-capture-$SFX"
TAG_RULE="retention-tagger-$SFX"
REC_RULE="evidence-recorder-$SFX"
ROLE="evidence-ingest-$SFX"
ALERT_TOPIC="evidence-intake-alerts-$SFX"
SEALER_SM="evidence-sealer-$SFX"
SEALER_ROLE="evidence-sealer-role-$SFX"
SSM_PARAM="/evidence/$SFX/archive-queue-url"

retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 10 ] && return 1; sleep 5; done; }

cat > ingest-trust.json <<'PY'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
PY
ROLE_ARN=$(retry aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document file://ingest-trust.json \
  --query Role.Arn --output text)
rm -f ingest-trust.json

# --- Queues.
ARCH_URL=$(retry aws sqs create-queue --queue-name "$ARCH_Q" --query QueueUrl --output text)
ARCH_ARN=$(retry aws sqs get-queue-attributes --queue-url "$ARCH_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)
RET_URL=$(retry aws sqs create-queue --queue-name "$RET_Q" --query QueueUrl --output text)
RET_ARN=$(retry aws sqs get-queue-attributes --queue-url "$RET_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

DLQ_URL=$(retry aws sqs create-queue --queue-name "$DLQ_Q" --query QueueUrl --output text)
DLQ_ARN=$(retry aws sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

CAP_RULE_ARN="arn:aws:events:$REGION:$ACCT:rule/$BUS/$CAP_RULE"
python3 - "$ARCH_ARN" "$ROLE_ARN" "$CAP_RULE_ARN" > arch-attrs.json <<'PY'
import json
import sys

qarn, role_arn, rule_arn = sys.argv[1], sys.argv[2], sys.argv[3]
policy = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowEvidenceIngestRole",
            "Effect": "Allow",
            "Principal": {"AWS": role_arn},
            "Action": "sqs:SendMessage",
            "Resource": qarn,
        },
        {
            "Sid": "AllowEventBridgeDeliver",
            "Effect": "Allow",
            "Principal": {"Service": "events.amazonaws.com"},
            "Action": "sqs:SendMessage",
            "Resource": qarn,
            "Condition": {"ArnEquals": {"aws:SourceArn": rule_arn}},
        },
    ],
}
print(json.dumps({"Policy": json.dumps(policy)}))
PY
# IAM role propagation: a resource policy naming a brand-new role can be
# rejected with MalformedPolicyDocument until the principal resolves.
retry aws sqs set-queue-attributes --queue-url "$ARCH_URL" --attributes file://arch-attrs.json
rm -f arch-attrs.json

# --- Ingest role identity policy, so the ingest path is coherent both sides.
python3 - "$ARCH_ARN" > ingest-perm.json <<'PY'
import json
import sys

print(json.dumps({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Action": "sqs:SendMessage", "Resource": sys.argv[1]}]}))
PY
retry aws iam put-role-policy --role-name "$ROLE" --policy-name send-to-archiver \
  --policy-document file://ingest-perm.json
rm -f ingest-perm.json

# --- Retention worker queue policy: healthy, grants EventBridge (restraint 2's
#     delivery leg must keep working).
python3 - "$RET_ARN" > ret-attrs.json <<'PY'
import json
import sys

qarn = sys.argv[1]
print(json.dumps({"Policy": json.dumps({
    "Version": "2012-10-17",
    "Statement": [{
        "Sid": "AllowEventBridgeDeliver",
        "Effect": "Allow",
        "Principal": {"Service": "events.amazonaws.com"},
        "Action": "sqs:SendMessage",
        "Resource": qarn,
    }],
})}))
PY
retry aws sqs set-queue-attributes --queue-url "$RET_URL" --attributes file://ret-attrs.json
rm -f ret-attrs.json

# --- The custom bus.
retry aws events create-event-bus --name "$BUS" >/dev/null

CAP_PATTERN="{\"source\":[\"aws.s3\"],\"detail-type\":[\"Object Created\"],\"detail\":{\"bucket\":{\"name\":[\"$BKT\"]}}}"
retry aws events put-rule --name "$CAP_RULE" --event-bus-name "$BUS" \
  --event-pattern "$CAP_PATTERN" --state ENABLED \
  --description "Capture evidence-store object writes for the archiver" >/dev/null
retry aws events put-targets --rule "$CAP_RULE" --event-bus-name "$BUS" \
  --targets "Id=archiver,Arn=$ARCH_ARN" >/dev/null

TOPIC_ARN=$(retry aws sns create-topic --name "$ALERT_TOPIC" --query TopicArn --output text)
# The intake-alert topic is one of the sources meant to feed the archive, and it is the
# only one whose purpose was not stated on the resource itself - the rules carry
# descriptions, the queues carry policies, and this carried nothing but its name. Say what
# it feeds, so an inventory built from configuration finds it the way the others are found.
# It stays UNSUBSCRIBED and UNGRANTED: what it is for is discoverable, wiring it up is not.
retry aws sns set-topic-attributes --topic-arn "$TOPIC_ARN" \
  --attribute-name DisplayName --attribute-value "Evidence intake alerts (compliance archive source)"
retry aws sns tag-resource --resource-arn "$TOPIC_ARN" \
  --tags "Key=Component,Value=compliance-evidence" "Key=DeliversTo,Value=$ARCH_Q"

retry aws events put-rule --name "$REC_RULE" --event-bus-name "$BUS" \
  --event-pattern '{"source":["acme.evidence"],"detail-type":["EvidenceRecorded"]}' \
  --state ENABLED --description "Route recorded-evidence events to the compliance archive" >/dev/null

retry aws events put-rule --name "$TAG_RULE" --event-bus-name "$BUS" \
  --event-pattern '{"source":["acme.evidence"],"detail-type":["EvidenceSealed"]}' \
  --state ENABLED --description "Route sealed-evidence events to the retention worker" >/dev/null
retry aws events put-targets --rule "$TAG_RULE" --event-bus-name "$BUS" \
  --targets "Id=retention,Arn=$RET_ARN" >/dev/null

cat > sealer-trust.json <<'PY'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}
PY
SEALER_ROLE_ARN=$(retry aws iam create-role --role-name "$SEALER_ROLE" \
  --assume-role-policy-document file://sealer-trust.json --query Role.Arn --output text)
rm -f sealer-trust.json
python3 - "$ARCH_ARN" "$DLQ_ARN" > sealer-perm.json <<'PY'
import json
import sys

print(json.dumps({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Action": "sqs:SendMessage",
     "Resource": [sys.argv[1], sys.argv[2]]}]}))
PY
retry aws iam put-role-policy --role-name "$SEALER_ROLE" --policy-name send-evidence \
  --policy-document file://sealer-perm.json
rm -f sealer-perm.json

python3 - "$DLQ_URL" > sealer-def.json <<'PY'
import json
import sys

print(json.dumps({
    "Comment": "Seal evidence and record it in the compliance archive",
    "StartAt": "RecordSealedEvidence",
    "States": {
        "RecordSealedEvidence": {
            "Type": "Task",
            "Resource": "arn:aws:states:::aws-sdk:sqs:sendMessage",
            "Parameters": {
                "QueueUrl": sys.argv[1],
                "MessageBody": "evidence-sealer: sealed evidence record",
            },
            "End": True,
        }
    },
}))
PY
SEALER_ARN=$(retry aws stepfunctions create-state-machine --name "$SEALER_SM" \
  --role-arn "$SEALER_ROLE_ARN" --definition file://sealer-def.json \
  --query stateMachineArn --output text)
rm -f sealer-def.json

retry aws ssm put-parameter --name "$SSM_PARAM" --type String --overwrite \
  --value "$DLQ_URL" \
  --description "Compliance archive queue (updated during the Q2 incident)" >/dev/null

if [ "$REGION" = "us-east-1" ]; then
  retry aws s3api create-bucket --bucket "$BKT" >/dev/null
else
  retry aws s3api create-bucket --bucket "$BKT" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
fi
retry aws s3api put-bucket-notification-configuration --bucket "$BKT" \
  --notification-configuration '{"EventBridgeConfiguration":{}}'
SEED_KEYS="intake/2026-07-24-batch.json intake/2026-07-26-batch.json intake/2026-07-27-batch.json"
for k in $SEED_KEYS; do
  printf '{"evidence":"seeded"}' > seed-obj.tmp
  retry aws s3api put-object --bucket "$BKT" --key "$k" --body seed-obj.tmp >/dev/null
done
rm -f seed-obj.tmp
SEED_KEYS_JSON=$(python3 -c "
import json
import sys
print(json.dumps(sys.argv[1].split()))" "$SEED_KEYS")

cat > seed_state.json <<EOF
{
  "suffix": "$SFX",
  "region": "$REGION",
  "account": "$ACCT",
  "bucket": "$BKT",
  "archiver_queue": "$ARCH_Q",
  "archiver_queue_url": "$ARCH_URL",
  "archiver_queue_arn": "$ARCH_ARN",
  "retention_queue": "$RET_Q",
  "retention_queue_url": "$RET_URL",
  "retention_queue_arn": "$RET_ARN",
  "bus": "$BUS",
  "capture_rule": "$CAP_RULE",
  "tagger_rule": "$TAG_RULE",
  "ingest_role": "$ROLE",
  "ingest_role_arn": "$ROLE_ARN",
  "dlq_queue": "$DLQ_Q",
  "dlq_queue_url": "$DLQ_URL",
  "dlq_queue_arn": "$DLQ_ARN",
  "alert_topic": "$ALERT_TOPIC",
  "alert_topic_arn": "$TOPIC_ARN",
  "recorder_rule": "$REC_RULE",
  "sealer_state_machine": "$SEALER_SM",
  "sealer_state_machine_arn": "$SEALER_ARN",
  "sealer_role": "$SEALER_ROLE",
  "ssm_param": "$SSM_PARAM",
  "seed_objects": $SEED_KEYS_JSON
}
EOF

echo "seeded evidence-event-routing $SFX (capture rule stranded on the custom bus"
echo "platform-events-$SFX, where aws.s3 events can never arrive; bucket IS emitting"
echo "to EventBridge; the archiver queue's EventBridge grant is pinned by"
echo "aws:SourceArn to the rule's CURRENT bus-qualified ARN, so re-homing the rule"
echo "silently disarms it; retention-tagger rule on the same bus is protected)"
