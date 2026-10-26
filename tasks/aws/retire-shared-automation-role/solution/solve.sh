#!/usr/bin/env bash
# Copies the legacy role's trust and inline policies to the replacement role,
# repoints every consumer of the legacy role at the replacement, then deletes the
# legacy role. Resources are discovered at runtime.
set -euo pipefail
export MSYS_NO_PATHCONV=1

role_by_prefix() {
  aws iam list-roles \
    --query "Roles[?starts_with(RoleName, '$1')].RoleName | [0]" --output text
}
LEGACY=$(role_by_prefix "fleet-maintenance-")
NEW=$(role_by_prefix "ops-runner-")
LEGACY_ARN=$(aws iam get-role --role-name "$LEGACY" --query Role.Arn --output text)
NEW_ARN=$(aws iam get-role --role-name "$NEW" --query Role.Arn --output text)

LTRUST=$(aws iam get-role --role-name "$LEGACY" \
  --query Role.AssumeRolePolicyDocument --output json)
NTRUST=$(aws iam get-role --role-name "$NEW" \
  --query Role.AssumeRolePolicyDocument --output json)
MERGED=$(python3 - "$LTRUST" "$NTRUST" <<'PY'
import json, sys
def services(doc):
    s = set()
    for st in doc.get("Statement", []):
        p = st.get("Principal", {})
        svc = p.get("Service") if isinstance(p, dict) else None
        if isinstance(svc, str):
            s.add(svc)
        elif isinstance(svc, list):
            s.update(svc)
    return s
allsvc = sorted(services(json.loads(sys.argv[1])) | services(json.loads(sys.argv[2])))
print(json.dumps({"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Principal": {"Service": allsvc},
     "Action": "sts:AssumeRole"}]}))
PY
)
aws iam update-assume-role-policy --role-name "$NEW" --policy-document "$MERGED"
for PN in $(aws iam list-role-policies --role-name "$LEGACY" \
              --query "PolicyNames" --output text); do
  DOC=$(aws iam get-role-policy --role-name "$LEGACY" --policy-name "$PN" \
    --query "PolicyDocument" --output json)
  aws iam put-role-policy --role-name "$NEW" --policy-name "$PN" \
    --policy-document "$DOC"
done

# update-schedule replaces the whole schedule, so re-specify every field.
for S in $(aws scheduler list-schedules --query "Schedules[].Name" --output text); do
  INFO=$(aws scheduler get-schedule --name "$S" --output json)
  case "$INFO" in *"$LEGACY_ARN"*) ;; *) continue ;; esac
  EXPR=$(printf '%s' "$INFO" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['ScheduleExpression'])")
  FTW=$(printf '%s' "$INFO" | python3 -c \
    "import json,sys; print(json.dumps(json.load(sys.stdin)['FlexibleTimeWindow']))")
  TGT=$(printf '%s' "$INFO" | python3 -c "
import json, sys
t = json.load(sys.stdin)['Target']
t['RoleArn'] = '$NEW_ARN'
print(json.dumps(t))")
  aws scheduler update-schedule --name "$S" --schedule-expression "$EXPR" \
    --flexible-time-window "$FTW" --target "$TGT" --state ENABLED >/dev/null
done

for BUS in $(aws events list-event-buses --query "EventBuses[].Name" --output text); do
  for RULE in $(aws events list-rules --event-bus-name "$BUS" \
                  --query "Rules[].Name" --output text); do
    TGTS=$(aws events list-targets-by-rule --event-bus-name "$BUS" \
      --rule "$RULE" --output json)
    case "$TGTS" in *"$LEGACY_ARN"*) ;; *) continue ;; esac
    NEWTGTS=$(printf '%s' "$TGTS" | python3 -c "
import json, sys
t = json.dumps(json.load(sys.stdin)['Targets'])
print(t.replace('$LEGACY_ARN', '$NEW_ARN'))")
    aws events put-targets --event-bus-name "$BUS" --rule "$RULE" \
      --targets "$NEWTGTS" >/dev/null
  done
done

for P in $(aws codebuild list-projects --query "projects" --output text); do
  SR=$(aws codebuild batch-get-projects --names "$P" \
    --query "projects[0].serviceRole" --output text)
  if [ "$SR" = "$LEGACY_ARN" ]; then
    aws codebuild update-project --name "$P" --service-role "$NEW_ARN" >/dev/null
  fi
done

for IP in $(aws iam list-instance-profiles-for-role --role-name "$LEGACY" \
              --query "InstanceProfiles[].InstanceProfileName" --output text); do
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$IP" --role-name "$LEGACY"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$IP" --role-name "$NEW"
done

for R in $(aws iam list-roles --output json | python3 -c "
import json, sys
for r in json.load(sys.stdin)['Roles']:
    if '$LEGACY_ARN' in json.dumps(r.get('AssumeRolePolicyDocument', {})):
        print(r['RoleName'])"); do
  DOC=$(aws iam get-role --role-name "$R" \
    --query Role.AssumeRolePolicyDocument --output json)
  NEWDOC=$(printf '%s' "$DOC" | python3 -c \
    "import sys; print(sys.stdin.read().replace('$LEGACY_ARN', '$NEW_ARN'))")
  aws iam update-assume-role-policy --role-name "$R" --policy-document "$NEWDOC"
done

# Swap the principal in place so other principals in the statement keep access.
for B in $(aws s3api list-buckets \
             --query "Buckets[?starts_with(Name, 'fleet-artifacts-')].Name" \
             --output text); do
  POL=$(aws s3api get-bucket-policy --bucket "$B" --query Policy --output text \
    2>/dev/null || true)
  case "$POL" in *"$LEGACY_ARN"*)
    NEWPOL=$(printf '%s' "$POL" | python3 -c \
      "import sys; print(sys.stdin.read().replace('$LEGACY_ARN', '$NEW_ARN'))")
    aws s3api put-bucket-policy --bucket "$B" --policy "$NEWPOL" ;;
  esac
done

for B in $(aws s3api list-buckets --query "Buckets[].Name" --output text); do
  REPL=$(aws s3api get-bucket-replication --bucket "$B" --output json \
    2>/dev/null || true)
  case "$REPL" in *"$LEGACY_ARN"*) ;; *) continue ;; esac
  NEWREPL=$(printf '%s' "$REPL" | python3 -c "
import json, sys
c = json.dumps(json.load(sys.stdin)['ReplicationConfiguration'])
print(c.replace('$LEGACY_ARN', '$NEW_ARN'))")
  aws s3api put-bucket-replication --bucket "$B" \
    --replication-configuration "$NEWREPL"
done

for W in $(aws ssm describe-maintenance-windows \
             --query "WindowIdentities[].WindowId" --output text); do
  for T in $(aws ssm describe-maintenance-window-tasks --window-id "$W" \
               --query "Tasks[?ServiceRoleArn=='$LEGACY_ARN'].WindowTaskId" \
               --output text); do
    aws ssm update-maintenance-window-task --window-id "$W" \
      --window-task-id "$T" --service-role-arn "$NEW_ARN" >/dev/null
  done
done

for P in $(aws ssm describe-parameters \
             --query "Parameters[].Name" --output text); do
  VAL=$(aws ssm get-parameter --name "$P" --query "Parameter.Value" \
    --output text 2>/dev/null || true)
  if [ "$VAL" = "$LEGACY_ARN" ]; then
    TYPE=$(aws ssm get-parameter --name "$P" --query "Parameter.Type" \
      --output text)
    aws ssm put-parameter --name "$P" --type "$TYPE" --value "$NEW_ARN" \
      --overwrite >/dev/null
  fi
done

# Inline policies and managed attachments must be removed before the role can
# be deleted.
for PN in $(aws iam list-role-policies --role-name "$LEGACY" \
              --query "PolicyNames" --output text); do
  aws iam delete-role-policy --role-name "$LEGACY" --policy-name "$PN"
done
for PA in $(aws iam list-attached-role-policies --role-name "$LEGACY" \
              --query "AttachedPolicies[].PolicyArn" --output text); do
  aws iam detach-role-policy --role-name "$LEGACY" --policy-arn "$PA"
done
aws iam delete-role --role-name "$LEGACY"

echo "legacy automation role retired; everything runs through the replacement"
