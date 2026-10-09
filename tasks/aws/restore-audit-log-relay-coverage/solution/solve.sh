#!/usr/bin/env bash
# Reference fix. Discovers everything at runtime; never reads seed_state.json.
set -euo pipefail
# Log group names start with "/"; keep Git Bash from rewriting them as Windows paths.
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"

ROLE_ARN="$(aws iam list-roles \
  --query 'Roles[?starts_with(RoleName,`audit-relay-cwl-`)].Arn' --output text | head -1)"
[ -n "$ROLE_ARN" ] || { echo "no relay role found" >&2; exit 1; }
ROLE_NAME="${ROLE_ARN##*/}"

REGIONS="$(aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name relay \
  --query 'PolicyDocument.Statement[].Resource' --output text \
  | tr '\t' '\n' | grep '^arn:aws:kinesis:' | cut -d: -f4 | sort -u)"
echo "audit relay regions named by the role's own grant: $(echo "$REGIONS" | tr '\n' ' ')"

for R in $REGIONS; do
  STREAM="$(aws kinesis list-streams --region "$R" --query 'StreamNames' --output text \
    | tr '\t' '\n' | grep '^audit-relay-stream-' | head -1 || true)"
  [ -n "${STREAM:-}" ] || { echo "no audit relay stream in $R, skipping"; continue; }
  STREAM_ARN="$(aws kinesis describe-stream --stream-name "$STREAM" --region "$R" \
    --query 'StreamDescription.StreamARN' --output text)"

  aws logs describe-log-groups --log-group-name-prefix /svc/ --region "$R" \
    --query 'logGroups[?logGroupClass==`INFREQUENT_ACCESS`].[logGroupName,retentionInDays]' \
    --output text | while read -r NAME RET; do
    [ -n "${NAME:-}" ] || continue
    echo "rebuilding $NAME in $R in the Standard class (retention ${RET})"
    aws logs delete-log-group --log-group-name "$NAME" --region "$R"
    aws logs create-log-group --log-group-name "$NAME" --log-group-class STANDARD --region "$R"
    if [ "$RET" != "None" ] && [ -n "$RET" ]; then
      aws logs put-retention-policy --log-group-name "$NAME" --retention-in-days "$RET" --region "$R"
    fi
  done

  for G in $(aws logs describe-log-groups --log-group-name-prefix /svc/ --region "$R" \
               --query 'logGroups[?logGroupClass==`STANDARD`].logGroupName' --output text); do
    for F in $(aws logs describe-subscription-filters --log-group-name "$G" --region "$R" \
                 --query 'subscriptionFilters[].filterName' --output text 2>/dev/null); do
      aws logs delete-subscription-filter --log-group-name "$G" --filter-name "$F" --region "$R" || true
    done
  done

  VENDOR="$(aws logs describe-log-groups --log-group-name-prefix /svc/vendor-callback-raw- \
    --region "$R" --query 'logGroups[0].logGroupName' --output text 2>/dev/null || true)"
  ARGS=(--policy-name audit-relay-all --policy-type SUBSCRIPTION_FILTER_POLICY --scope ALL
        --policy-document "{\"DestinationArn\":\"${STREAM_ARN}\",\"RoleArn\":\"${ROLE_ARN}\",\"FilterPattern\":\"\",\"Distribution\":\"Random\"}"
        --region "$R")
  if [ -n "${VENDOR:-}" ] && [ "$VENDOR" != "None" ]; then
    ARGS+=(--selection-criteria "LogGroupName NOT IN [\"${VENDOR}\"]")
    echo "$R: account-wide relay to ${STREAM}, ${VENDOR} excluded"
  else
    echo "$R: account-wide relay to ${STREAM}"
  fi
  aws logs put-account-policy "${ARGS[@]}" >/dev/null
done
