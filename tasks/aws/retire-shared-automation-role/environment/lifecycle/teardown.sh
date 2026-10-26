#!/usr/bin/env bash
# Best-effort cleanup of everything setup created; never fails.
set -uo pipefail
export MSYS_NO_PATHCONV=1

SFX=$(python3 -c "import json; print(json.load(open('seed_state.json'))['suffix'])" 2>/dev/null) || exit 0
[ -n "$SFX" ] || exit 0

aws scheduler delete-schedule --name "nightly-fleet-sweep-$SFX" >/dev/null 2>&1 || true
aws scheduler delete-schedule --name "hourly-metrics-$SFX" >/dev/null 2>&1 || true

aws codebuild delete-project --name "image-bake-$SFX" >/dev/null 2>&1 || true

aws ssm delete-parameter --name "/vera-$SFX/dispatch/runner-role" >/dev/null 2>&1 || true
aws ssm delete-parameter --name "/vera-$SFX/dispatch/reporting-role" >/dev/null 2>&1 || true

aws events remove-targets --event-bus-name "platform-bus-$SFX" \
  --rule "inventory-kick-$SFX" --ids 1 >/dev/null 2>&1 || true
aws events delete-rule --event-bus-name "platform-bus-$SFX" \
  --name "inventory-kick-$SFX" >/dev/null 2>&1 || true
aws events delete-event-bus --name "platform-bus-$SFX" >/dev/null 2>&1 || true
ACCT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || ACCT=""
[ -n "$ACCT" ] && aws stepfunctions delete-state-machine \
  --state-machine-arn "arn:aws:states:${AWS_REGION:-us-east-1}:$ACCT:stateMachine:inventory-flow-$SFX" \
  >/dev/null 2>&1 || true

aws ec2 delete-launch-template --launch-template-name "fleet-node-$SFX" >/dev/null 2>&1 || true

# Instance profiles: empty them of whatever roles they hold now, then delete.
for IP in "fleet-node-profile-$SFX" "ops-node-profile-$SFX"; do
  for R in $(aws iam get-instance-profile --instance-profile-name "$IP" \
               --query "InstanceProfile.Roles[].RoleName" --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$IP" \
      --role-name "$R" >/dev/null 2>&1 || true
  done
  aws iam delete-instance-profile --instance-profile-name "$IP" >/dev/null 2>&1 || true
done

MWID=$(python3 -c "import json; print(json.load(open('seed_state.json')).get('mw_id',''))" 2>/dev/null) || MWID=""
[ -n "$MWID" ] && aws ssm delete-maintenance-window --window-id "$MWID" >/dev/null 2>&1 || true

for B in "fleet-artifacts-$SFX" "data-mirror-$SFX"; do
  aws s3api delete-bucket-replication --bucket "$B" >/dev/null 2>&1 || true
  # versioned buckets: delete every version and delete marker, then the bucket
  aws s3api list-object-versions --bucket "$B" \
    --query "[Versions[].[Key,VersionId],DeleteMarkers[].[Key,VersionId]][]" \
    --output text 2>/dev/null | while read -r K V; do
    [ -n "${K:-}" ] && aws s3api delete-object --bucket "$B" --key "$K" \
      --version-id "$V" >/dev/null 2>&1 || true
  done
  aws s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$B" >/dev/null 2>&1 || true
done

QURL=$(aws sqs get-queue-url --queue-name "fleet-events-$SFX" \
  --query QueueUrl --output text 2>/dev/null) || QURL=""
[ -n "$QURL" ] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true

for ROLE in "fleet-maintenance-$SFX" "ops-runner-$SFX" "release-gate-$SFX" \
            "compliance-scan-$SFX" "metrics-agent-$SFX" "flow-exec-$SFX"; do
  for IP in $(aws iam list-instance-profiles-for-role --role-name "$ROLE" \
                --query "InstanceProfiles[].InstanceProfileName" --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$IP" \
      --role-name "$ROLE" >/dev/null 2>&1 || true
  done
  for PN in $(aws iam list-role-policies --role-name "$ROLE" \
                --query "PolicyNames" --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$PN" \
      >/dev/null 2>&1 || true
  done
  for PA in $(aws iam list-attached-role-policies --role-name "$ROLE" \
                --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$PA" \
      >/dev/null 2>&1 || true
  done
  aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
done

exit 0
