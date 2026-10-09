#!/usr/bin/env bash
# Creates the legacy fleet automation role, its replacement, and the resources
# that run through the legacy role. Identifiers are written to seed_state.json.
set -euo pipefail
export MSYS_NO_PATHCONV=1

REGION="${AWS_REGION:-us-east-1}"
SFX="${RANDOM}${RANDOM}"
LEGACY_ROLE="fleet-maintenance-$SFX"
NEW_ROLE="ops-runner-$SFX"
GATE_ROLE="release-gate-$SFX"
COMP_ROLE="compliance-scan-$SFX"
METRICS_ROLE="metrics-agent-$SFX"
PROF_A="fleet-node-profile-$SFX"
PROF_B="ops-node-profile-$SFX"
LT_NAME="fleet-node-$SFX"
BUCKET="fleet-artifacts-$SFX"
QUEUE="fleet-events-$SFX"
SCHED="nightly-fleet-sweep-$SFX"
SCHED_PROT="hourly-metrics-$SFX"
CB="image-bake-$SFX"
BUS="platform-bus-$SFX"
BUS_RULE="inventory-kick-$SFX"
SFN_NAME="inventory-flow-$SFX"
SFN_ROLE="flow-exec-$SFX"
MIRROR="data-mirror-$SFX"
MW_NAME="patch-cycle-$SFX"
PARAM_RUNNER="/vera-$SFX/dispatch/runner-role"
PARAM_REPORT="/vera-$SFX/dispatch/reporting-role"
ARTIFACT_KEY="artifacts/manifest.json"
ARTIFACT_BODY="fleet artifact manifest build 2026-07-01 nodes 14 seed $SFX"

ACCT=$(aws sts get-caller-identity --query Account --output text)

# Fresh IAM principals propagate slowly; anything that validates one can fail
# transiently, so wrap those calls in a retry.
retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 10 ] && return 1; sleep 5; done; }

QURL=$(aws sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)
QARN=$(aws sqs get-queue-attributes --queue-url "$QURL" \
  --attribute-names QueueArn --query "Attributes.QueueArn" --output text)

LEGACY_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["scheduler.amazonaws.com","codebuild.amazonaws.com","ec2.amazonaws.com","events.amazonaws.com","ssm.amazonaws.com","s3.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'
NEW_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":["scheduler.amazonaws.com","codebuild.amazonaws.com","ec2.amazonaws.com","events.amazonaws.com","s3.amazonaws.com"]},"Action":"sts:AssumeRole"}]}'
SFN_ARN="arn:aws:states:$REGION:$ACCT:stateMachine:$SFN_NAME"
REPL_PERMS="{\"Effect\":\"Allow\",\"Action\":[\"s3:GetReplicationConfiguration\",\"s3:ListBucket\",\"s3:GetObjectVersionForReplication\",\"s3:GetObjectVersionAcl\",\"s3:ReplicateObject\",\"s3:ReplicateDelete\"],\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\",\"arn:aws:s3:::$MIRROR/*\"]}"
LEGACY_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$QARN\"},{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/artifacts/*\"},{\"Effect\":\"Allow\",\"Action\":\"states:StartExecution\",\"Resource\":\"$SFN_ARN\"},$REPL_PERMS]}"
NEW_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$QARN\"},{\"Effect\":\"Allow\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/artifacts/*\"},$REPL_PERMS]}"

LEGACY_RID=$(aws iam create-role --role-name "$LEGACY_ROLE" \
  --assume-role-policy-document "$LEGACY_TRUST" \
  --query Role.RoleId --output text)
aws iam create-role --role-name "$NEW_ROLE" \
  --assume-role-policy-document "$NEW_TRUST" >/dev/null
aws iam put-role-policy --role-name "$LEGACY_ROLE" --policy-name task-access \
  --policy-document "$LEGACY_POLICY"
aws iam put-role-policy --role-name "$NEW_ROLE" --policy-name task-access \
  --policy-document "$NEW_POLICY"
LEGACY_ARN="arn:aws:iam::$ACCT:role/$LEGACY_ROLE"
NEW_ARN="arn:aws:iam::$ACCT:role/$NEW_ROLE"

aws iam create-role --role-name "$COMP_ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
COMP_ARN="arn:aws:iam::$ACCT:role/$COMP_ROLE"

aws iam create-role --role-name "$METRICS_ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam put-role-policy --role-name "$METRICS_ROLE" --policy-name send-metrics \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sqs:SendMessage\",\"Resource\":\"$QARN\"}]}"
METRICS_ARN="arn:aws:iam::$ACCT:role/$METRICS_ROLE"

retry aws iam create-role --role-name "$GATE_ROLE" --assume-role-policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"$LEGACY_ARN\"},\"Action\":\"sts:AssumeRole\"}]}" >/dev/null
aws iam put-role-policy --role-name "$GATE_ROLE" --policy-name release-approve \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameter\",\"ssm:GetParameters\"],\"Resource\":\"arn:aws:ssm:$REGION:$ACCT:parameter/release/*\"}]}"

aws ssm put-parameter --name "$PARAM_RUNNER" --type String \
  --value "$LEGACY_ARN" --overwrite >/dev/null
aws ssm put-parameter --name "$PARAM_REPORT" --type String \
  --value "$METRICS_ARN" --overwrite >/dev/null

aws iam create-instance-profile --instance-profile-name "$PROF_A" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$PROF_A" --role-name "$LEGACY_ROLE"
aws iam create-instance-profile --instance-profile-name "$PROF_B" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$PROF_B" --role-name "$NEW_ROLE"

LTID=$(aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
  --version-description "fleet node baseline" \
  --launch-template-data "{\"InstanceType\":\"t3.micro\",\"IamInstanceProfile\":{\"Name\":\"$PROF_A\"}}" \
  --query "LaunchTemplate.LaunchTemplateId" --output text)
aws ec2 create-launch-template-version --launch-template-id "$LTID" \
  --version-description "ami refresh" \
  --launch-template-data "{\"InstanceType\":\"t3.micro\",\"IamInstanceProfile\":{\"Name\":\"$PROF_B\"}}" >/dev/null

if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" >/dev/null
else
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
fi
printf '%s' "$ARTIFACT_BODY" > artifact.tmp
aws s3api put-object --bucket "$BUCKET" --key "$ARTIFACT_KEY" --body artifact.tmp >/dev/null
rm -f artifact.tmp
retry aws s3api put-bucket-policy --bucket "$BUCKET" --policy \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"ArtifactRead\",\"Effect\":\"Allow\",\"Principal\":{\"AWS\":[\"$LEGACY_ARN\",\"$COMP_ARN\"]},\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/artifacts/*\"}]}"

aws s3api create-bucket --bucket "$MIRROR" >/dev/null
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-versioning --bucket "$MIRROR" \
  --versioning-configuration Status=Enabled
retry aws s3api put-bucket-replication --bucket "$BUCKET" \
  --replication-configuration "{\"Role\":\"$LEGACY_ARN\",\"Rules\":[{\"ID\":\"archive\",\"Status\":\"Enabled\",\"Priority\":1,\"DeleteMarkerReplication\":{\"Status\":\"Disabled\"},\"Filter\":{\"Prefix\":\"\"},\"Destination\":{\"Bucket\":\"arn:aws:s3:::$MIRROR\"}}]}"

MWID=$(retry aws ssm create-maintenance-window --name "$MW_NAME" \
  --schedule "cron(0 4 ? * SUN *)" --duration 2 --cutoff 1 \
  --allow-unassociated-targets --query WindowId --output text)
WTID=$(retry aws ssm register-target-with-maintenance-window \
  --window-id "$MWID" --resource-type INSTANCE \
  --targets "Key=tag:NodeGroup,Values=batch-$SFX" \
  --query WindowTargetId --output text)
retry aws ssm register-task-with-maintenance-window --window-id "$MWID" \
  --task-arn "AWS-RestartEC2Instance" --task-type AUTOMATION \
  --targets "Key=WindowTargetIds,Values=$WTID" \
  --service-role-arn "$LEGACY_ARN" \
  --max-concurrency 1 --max-errors 1 --priority 2 >/dev/null

retry aws scheduler create-schedule --name "$SCHED" \
  --schedule-expression "cron(15 2 * * ? *)" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --target "{\"Arn\":\"$QARN\",\"RoleArn\":\"$LEGACY_ARN\",\"Input\":\"{\\\"job\\\":\\\"nightly-sweep\\\"}\"}" >/dev/null
retry aws scheduler create-schedule --name "$SCHED_PROT" \
  --schedule-expression "rate(1 hour)" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --target "{\"Arn\":\"$QARN\",\"RoleArn\":\"$METRICS_ARN\",\"Input\":\"{\\\"job\\\":\\\"metrics\\\"}\"}" >/dev/null

aws iam create-role --role-name "$SFN_ROLE" --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
retry aws stepfunctions create-state-machine --name "$SFN_NAME" \
  --role-arn "arn:aws:iam::$ACCT:role/$SFN_ROLE" \
  --definition '{"StartAt":"Done","States":{"Done":{"Type":"Pass","End":true}}}' >/dev/null
aws events create-event-bus --name "$BUS" >/dev/null
aws events put-rule --name "$BUS_RULE" --event-bus-name "$BUS" \
  --event-pattern '{"source":["platform.inventory"]}' --state ENABLED >/dev/null
retry aws events put-targets --event-bus-name "$BUS" --rule "$BUS_RULE" \
  --targets "[{\"Id\":\"1\",\"Arn\":\"$SFN_ARN\",\"RoleArn\":\"$LEGACY_ARN\"}]" >/dev/null

retry aws codebuild create-project --name "$CB" \
  --source '{"type":"NO_SOURCE","buildspec":"version: 0.2\nphases:\n  build:\n    commands:\n      - echo bake"}' \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"}' \
  --service-role "$LEGACY_ARN" >/dev/null

cat > seed_state.json <<EOF
{
  "suffix": "$SFX",
  "region": "$REGION",
  "account": "$ACCT",
  "legacy_role": "$LEGACY_ROLE",
  "legacy_role_arn": "$LEGACY_ARN",
  "legacy_role_id": "$LEGACY_RID",
  "new_role": "$NEW_ROLE",
  "new_role_arn": "$NEW_ARN",
  "gate_role": "$GATE_ROLE",
  "compliance_role": "$COMP_ROLE",
  "compliance_role_arn": "$COMP_ARN",
  "metrics_role": "$METRICS_ROLE",
  "metrics_role_arn": "$METRICS_ARN",
  "profile_legacy": "$PROF_A",
  "profile_new": "$PROF_B",
  "launch_template_id": "$LTID",
  "launch_template_name": "$LT_NAME",
  "bucket": "$BUCKET",
  "queue_url": "$QURL",
  "queue_arn": "$QARN",
  "schedule": "$SCHED",
  "schedule_expression": "cron(15 2 * * ? *)",
  "schedule_input": "{\"job\":\"nightly-sweep\"}",
  "schedule_protected": "$SCHED_PROT",
  "codebuild_project": "$CB",
  "event_bus": "$BUS",
  "bus_rule": "$BUS_RULE",
  "sfn_arn": "$SFN_ARN",
  "sfn_role": "$SFN_ROLE",
  "mirror_bucket": "$MIRROR",
  "mw_id": "$MWID",
  "mw_name": "$MW_NAME",
  "param_runner": "$PARAM_RUNNER",
  "param_report": "$PARAM_REPORT",
  "artifact_key": "$ARTIFACT_KEY",
  "artifact_content": "$ARTIFACT_BODY"
}
EOF

echo "seeded fleet platform $SFX: legacy role referenced by schedule, codebuild"
echo "project, instance profile behind the LT \$Default, release-gate trust, and"
echo "a shared bucket-policy statement; replacement role + migrated v2 profile"
echo "already in place; protected metrics schedule and compliance grant present"
