#!/usr/bin/env bash
# Moves the evidence capture rule to the default event bus, wires the recorder
# rule, sealer state machine and SNS alert topic to the archiver queue, updates
# the queue policy to match, and replays the objects already in the bucket.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"

retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 10 ] && return 1; sleep 5; done; }

BKT=$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, 'evidence-store-')].Name | [0]" --output text)
# The evidence-archiver- prefix also matches the dead-letter queue and
# list-queues is unordered, so exclude the dead-letter queue by name.
ARCH_URL=$(aws sqs list-queues --queue-name-prefix evidence-archiver- \
  --query "QueueUrls[?!contains(@, 'evidence-archiver-dlq-')] | [0]" --output text)
ARCH_ARN=$(aws sqs get-queue-attributes --queue-url "$ARCH_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)
BUS=$(aws events list-event-buses \
  --query "EventBuses[?starts_with(Name, 'platform-events-')].Name | [0]" --output text)
TOPIC_ARN=$(aws sns list-topics \
  --query "Topics[?contains(TopicArn, 'evidence-intake-alerts-')].TopicArn | [0]" --output text)
REC_RULE=$(aws events list-rules --event-bus-name "$BUS" \
  --query "Rules[?starts_with(Name, 'evidence-recorder-')].Name | [0]" --output text)

# Read the existing capture rule's pattern so the new rule matches it.
CAP_RULE=$(aws events list-rules --event-bus-name "$BUS" \
  --query "Rules[?starts_with(Name, 'evidence-capture-')].Name | [0]" --output text)
CAP_PATTERN=$(aws events describe-rule --name "$CAP_RULE" --event-bus-name "$BUS" \
  --query EventPattern --output text)

echo "bucket=$BKT archiver=$ARCH_ARN bus=$BUS rule=$CAP_RULE"

# Recreate the capture rule on the default bus, where S3 events are delivered.
# This changes the rule's ARN.
retry aws events put-rule --name "$CAP_RULE" --event-pattern "$CAP_PATTERN" \
  --state ENABLED --description "Capture evidence-store object writes for the archiver" >/dev/null
retry aws events put-targets --rule "$CAP_RULE" \
  --targets "Id=archiver,Arn=$ARCH_ARN" >/dev/null
NEW_RULE_ARN=$(aws events describe-rule --name "$CAP_RULE" --query Arn --output text)
echo "re-homed rule ARN=$NEW_RULE_ARN"

# The recorder rule has no target; point it at the archiver queue.
retry aws events put-targets --rule "$REC_RULE" --event-bus-name "$BUS" \
  --targets "Id=archiver,Arn=$ARCH_ARN" >/dev/null
REC_RULE_ARN=$(aws events describe-rule --name "$REC_RULE" --event-bus-name "$BUS" \
  --query Arn --output text)
echo "recorder rule ARN=$REC_RULE_ARN"

# The sealer state machine sends to the dead-letter queue; repoint it at the
# archiver queue.
SEALER_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?starts_with(name, 'evidence-sealer-')].stateMachineArn | [0]" --output text)
if [ -n "${SEALER_ARN:-}" ] && [ "$SEALER_ARN" != "None" ]; then
  aws stepfunctions describe-state-machine --state-machine-arn "$SEALER_ARN" \
    --query definition --output text > sealer-cur.json
  DLQ_URL=$(aws sqs list-queues --queue-name-prefix evidence-archiver-dlq- \
    --query "QueueUrls[0]" --output text)
  python3 - "$ARCH_URL" "$DLQ_URL" > sealer-new.json <<'PY'
import json
import sys

d = json.load(open("sealer-cur.json"))
arch, dlq = sys.argv[1], sys.argv[2]
for state in d.get("States", {}).values():
    params = state.get("Parameters", {})
    if params.get("QueueUrl") in (dlq, None) and "QueueUrl" in params:
        params["QueueUrl"] = arch
print(json.dumps(d))
PY
  retry aws stepfunctions update-state-machine --state-machine-arn "$SEALER_ARN" \
    --definition file://sealer-new.json >/dev/null
  rm -f sealer-cur.json sealer-new.json
  echo "repointed sealer state machine at the archive"
fi

# Subscribe the archiver queue to the SNS intake-alert topic.
if [ -n "${TOPIC_ARN:-}" ] && [ "$TOPIC_ARN" != "None" ]; then
  retry aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol sqs \
    --notification-endpoint "$ARCH_ARN" >/dev/null
  echo "subscribed archive to $TOPIC_ARN"
fi

# Update the queue policy's aws:SourceArn condition to the new rule ARNs.
# SetQueueAttributes replaces the whole policy, so the other statements are
# carried over.
CUR_POLICY=$(aws sqs get-queue-attributes --queue-url "$ARCH_URL" \
  --attribute-names Policy --query "Attributes.Policy" --output text)
python3 - "$ARCH_ARN" "$CUR_POLICY" "$NEW_RULE_ARN,$REC_RULE_ARN" > arch-attrs.json <<'PY'
import json
import sys

qarn, cur, new_rule_arn = sys.argv[1], sys.argv[2], sys.argv[3]
policy = json.loads(cur) if cur and cur != "None" else {"Version": "2012-10-17", "Statement": []}
stmts = policy.setdefault("Statement", [])

# Re-point an existing events.amazonaws.com grant if there is one; otherwise add it.
# The condition must cover both rules that now deliver here (the re-homed capture
# rule on the default bus and the recorder rule on the custom bus), so the pin
# becomes a list rather than a single ARN.
found = False
for st in stmts:
    principal = st.get("Principal", {})
    svc = principal.get("Service", []) if isinstance(principal, dict) else []
    if isinstance(svc, str):
        svc = [svc]
    if "events.amazonaws.com" in svc:
        st["Condition"] = {"ArnEquals": {"aws:SourceArn": new_rule_arn.split(",")}}
        found = True
if not found:
    stmts.append({
        "Sid": "AllowEventBridgeDeliver",
        "Effect": "Allow",
        "Principal": {"Service": "events.amazonaws.com"},
        "Action": "sqs:SendMessage",
        "Resource": qarn,
        "Condition": {"ArnEquals": {"aws:SourceArn": new_rule_arn.split(",")}},
    })

# The SNS intake-alert path needs its own grant - subscribing the queue to the
# topic is not enough if the queue will not accept a message from sns.
if not any("sns.amazonaws.com" in (
        [s] if isinstance(s := st.get("Principal", {}).get("Service", []), str) else s)
        for st in stmts if isinstance(st.get("Principal"), dict)):
    stmts.append({
        "Sid": "AllowIntakeAlertsDeliver",
        "Effect": "Allow",
        "Principal": {"Service": "sns.amazonaws.com"},
        "Action": "sqs:SendMessage",
        "Resource": qarn,
    })
print(json.dumps({"Policy": json.dumps(policy)}))
PY
retry aws sqs set-queue-attributes --queue-url "$ARCH_URL" --attributes file://arch-attrs.json
rm -f arch-attrs.json

echo "waiting for the repaired routing to start carrying traffic before replaying"
sleep 120
for KEY in $(aws s3api list-objects-v2 --bucket "$BKT" --query 'Contents[].Key' --output text); do
  [ -n "$KEY" ] || continue
  retry aws s3api copy-object --bucket "$BKT" --key "$KEY" \
    --copy-source "$BKT/$KEY" --metadata-directive REPLACE \
    --metadata "archive-backfill=$(date -u +%Y%m%dT%H%M%SZ)" >/dev/null
  echo "backfilled $KEY"
done

# Remove the unused capture rule from the custom bus. The bus and the
# retention-tagger rule are left in place.
aws events remove-targets --rule "$CAP_RULE" --event-bus-name "$BUS" --ids archiver >/dev/null 2>&1 || true
aws events delete-rule --name "$CAP_RULE" --event-bus-name "$BUS" >/dev/null 2>&1 || true

echo "evidence capture re-homed onto the default event bus; archiver queue policy"
echo "grants EventBridge and still grants the ingest role; platform-events bus and"
echo "retention-tagger rule untouched"
