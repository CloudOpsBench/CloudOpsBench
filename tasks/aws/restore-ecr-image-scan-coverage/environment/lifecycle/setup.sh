#!/usr/bin/env bash
# Creates ECR repositories in two regions with a registry scanning configuration
# that matches only some of them, cross-region replication, and an EventBridge
# rule that forwards scan events for one repository to an SNS topic. The seeded
# state is recorded in seed_state.json for the checker.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
WEST="us-west-2"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
TAGK="Project"
TAGV="scanpolicy-demo"

# Remove leftovers from an earlier run.
for r in $(aws ecr describe-repositories --region "$REGION" --query 'repositories[].repositoryName' --output text 2>/dev/null); do
  arn="arn:aws:ecr:${REGION}:${ACCT}:repository/${r}"
  if aws ecr list-tags-for-resource --resource-arn "$arn" --region "$REGION" \
       --query "length(tags[?Key=='${TAGK}' && (Value=='${TAGV}' || Value=='data-platform')])" --output text 2>/dev/null | grep -qx 1; then
    aws ecr delete-repository --repository-name "$r" --force --region "$REGION" >/dev/null 2>&1 || true
  fi
done
for r in $(aws ecr describe-repositories --region "$WEST" --query 'repositories[].repositoryName' --output text 2>/dev/null); do
  arn="arn:aws:ecr:${WEST}:${ACCT}:repository/${r}"
  if aws ecr list-tags-for-resource --resource-arn "$arn" --region "$WEST"        --query "length(tags[?Key=='${TAGK}' && Value=='${TAGV}'])" --output text 2>/dev/null | grep -qx 1; then
    aws ecr delete-repository --repository-name "$r" --force --region "$WEST" >/dev/null 2>&1 || true
  fi
done
aws ecr put-replication-configuration --region "$REGION" --replication-configuration '{"rules":[]}' >/dev/null 2>&1 || true
aws ecr put-registry-scanning-configuration --region "$WEST" --scan-type BASIC --rules '[]' >/dev/null 2>&1 || true

for rl in $(aws events list-rules --name-prefix ecr-scan-findings- --region "$REGION" --query 'Rules[].Name' --output text 2>/dev/null); do
  for t in $(aws events list-targets-by-rule --rule "$rl" --region "$REGION" --query 'Targets[].Id' --output text 2>/dev/null); do
    aws events remove-targets --rule "$rl" --ids "$t" --region "$REGION" >/dev/null 2>&1 || true
  done
  aws events delete-rule --name "$rl" --region "$REGION" >/dev/null 2>&1 || true
done
for tp in $(aws sns list-topics --region "$REGION" --query 'Topics[].TopicArn' --output text 2>/dev/null); do
  case "$tp" in *:sec-scan-findings-*) aws sns delete-topic --topic-arn "$tp" --region "$REGION" >/dev/null 2>&1 || true ;; esac
done

SUF="$(python3 -c 'import secrets;print(secrets.token_hex(4))')"

APP1="svc-payments-api-${SUF}"
APP2="svc-orders-api-${SUF}"
APP3="svc-inventory-api-${SUF}"
APP4="platform-shared/svc-fraud-api-${SUF}"
MIRROR="mirror-upstream-cache-${SUF}"
APP5="svc-checkout-api-${SUF}"
OTHER1="data-platform-etl-${SUF}"
OTHER2="data-platform-ingest-${SUF}"
TOPIC="sec-scan-findings-${SUF}"
RULE="ecr-scan-findings-${SUF}"

for r in "$OTHER1" "$OTHER2"; do
  aws ecr create-repository --repository-name "$r" --region "$REGION" \
    --tags "Key=${TAGK},Value=data-platform" >/dev/null
  aws ecr put-image-scanning-configuration --repository-name "$r" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true >/dev/null
done

for r in "$APP1" "$APP2" "$APP3" "$APP4" "$MIRROR"; do
  aws ecr create-repository --repository-name "$r" --region "$REGION" \
    --tags "Key=${TAGK},Value=${TAGV}" >/dev/null
  # Repository-level scanOnPush is enabled on every repository.
  aws ecr put-image-scanning-configuration --repository-name "$r" --region "$REGION" \
    --image-scanning-configuration scanOnPush=true >/dev/null
done

aws ecr put-registry-scanning-configuration --region "$REGION" --scan-type BASIC --rules "$(
  python3 - "$APP1" "data-platform-*-${SUF}" <<'PY'
import json,sys
print(json.dumps([{"scanFrequency":"SCAN_ON_PUSH",
                   "repositoryFilters":[{"filter":f,"filterType":"WILDCARD"} for f in sys.argv[1:]]}]))
PY
)" >/dev/null

aws ecr create-repository --repository-name "$APP5" --region "$WEST"   --tags "Key=${TAGK},Value=${TAGV}" >/dev/null
aws ecr put-image-scanning-configuration --repository-name "$APP5" --region "$WEST"   --image-scanning-configuration scanOnPush=true >/dev/null
aws ecr put-registry-scanning-configuration --region "$WEST" --scan-type BASIC --rules '[]' >/dev/null

# Replicate svc-* repositories to the registry in the second region.
aws ecr put-replication-configuration --region "$REGION" --replication-configuration "$(
  python3 - "$ACCT" "$WEST" <<'PYR'
import json,sys
print(json.dumps({"rules":[{"destinations":[{"region":sys.argv[2],"registryId":sys.argv[1]}],
                            "repositoryFilters":[{"filter":"svc-","filterType":"PREFIX_MATCH"}]}]}))
PYR
)" >/dev/null

TOPIC_ARN="$(aws sns create-topic --name "$TOPIC" --region "$REGION" --query TopicArn --output text)"
aws sns set-topic-attributes --topic-arn "$TOPIC_ARN" --region "$REGION" \
  --attribute-name Policy --attribute-value "$(
  python3 - "$TOPIC_ARN" <<'PY'
import json,sys
print(json.dumps({"Version":"2012-10-17","Statement":[
  {"Sid":"OwnerFull","Effect":"Allow","Principal":{"AWS":sys.argv[1].split(":")[4]},
   "Action":["SNS:Publish","SNS:Subscribe","SNS:GetTopicAttributes","SNS:SetTopicAttributes",
              "SNS:ListSubscriptionsByTopic","SNS:AddPermission","SNS:RemovePermission","SNS:DeleteTopic"],
   "Resource":sys.argv[1]},
  {"Sid":"AllowEventBridgePublish","Effect":"Allow","Principal":{"Service":"events.amazonaws.com"},
   "Action":"sns:Publish","Resource":sys.argv[1]}]}))
PY
)" >/dev/null

aws events put-rule --name "$RULE" --region "$REGION" --state ENABLED \
  --description "Forward container image scan findings to the security topic" \
  --event-pattern "$(
  python3 - "$APP1" <<'PY'
import json,sys
print(json.dumps({"source":["aws.ecr"],"detail-type":["ECR Image Scan"],
                  "detail":{"repository-name":[sys.argv[1]]}}))
PY
)" >/dev/null
aws events put-targets --rule "$RULE" --region "$REGION" \
  --targets "Id=security-topic,Arn=${TOPIC_ARN}" >/dev/null

python3 - "$REGION" "$ACCT" "$SUF" "$APP1" "$APP2" "$APP3" "$APP4" "$MIRROR" "$TOPIC_ARN" "$RULE" "$OTHER1" "$OTHER2" "$APP5" "$WEST" <<'PY'
import json, sys, boto3
region, acct, suf = sys.argv[1], sys.argv[2], sys.argv[3]
apps = sys.argv[4:8]; mirror = sys.argv[8]; topic = sys.argv[9]; rule = sys.argv[10]
others = sys.argv[11:13]
app5, west = sys.argv[13], sys.argv[14]
ecr = boto3.client("ecr", region_name=region)
ecr_w = boto3.client("ecr", region_name=west)
ident = {}
for r in apps + [mirror] + others:
    d = ecr.describe_repositories(repositoryNames=[r])["repositories"][0]
    ident[r] = {"repositoryArn": d["repositoryArn"],
                "createdAt": d["createdAt"].isoformat(),
                "encryptionConfiguration": d.get("encryptionConfiguration", {}),
                "imageTagMutability": d.get("imageTagMutability")}
d = ecr_w.describe_repositories(repositoryNames=[app5])["repositories"][0]
ident[app5] = {"repositoryArn": d["repositoryArn"], "createdAt": d["createdAt"].isoformat(),
               "encryptionConfiguration": d.get("encryptionConfiguration", {}),
               "imageTagMutability": d.get("imageTagMutability"), "region": west}
json.dump({"region": region, "west_region": west, "west_app_repos": [app5], "account": acct, "suffix": suf,
           "app_repos": apps, "mirror_repo": mirror, "other_team_repos": others,
           "topic_arn": topic, "rule_name": rule,
           "repo_identity": ident}, open("seed_state.json", "w"), indent=2)
PY
echo "seeded registry: 4 application repositories + ${MIRROR}"
