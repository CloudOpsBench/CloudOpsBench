#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"
S=seed_state.json
[ -f "$S" ] || exit 0
python3 - "$S" <<'PY' > /tmp/_teardown_vals 2>/dev/null || exit 0
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(d["app_repos"]+[d["mirror_repo"]]+d.get("other_team_repos",[])))
print(d["topic_arn"]); print(d["rule_name"])
print(" ".join(d.get("west_app_repos",[]))); print(d.get("west_region","us-west-2"))
PY
REPOS="$(sed -n 1p /tmp/_teardown_vals)"; TOPIC="$(sed -n 2p /tmp/_teardown_vals)"; RULE="$(sed -n 3p /tmp/_teardown_vals)"
for t in $(aws events list-targets-by-rule --rule "$RULE" --region "$REGION" --query 'Targets[].Id' --output text 2>/dev/null); do
  aws events remove-targets --rule "$RULE" --ids "$t" --region "$REGION" >/dev/null 2>&1 || true
done
aws events delete-rule --name "$RULE" --region "$REGION" >/dev/null 2>&1 || true
aws sns delete-topic --topic-arn "$TOPIC" --region "$REGION" >/dev/null 2>&1 || true
for r in $REPOS; do aws ecr delete-repository --repository-name "$r" --force --region "$REGION" >/dev/null 2>&1 || true; done
WREPOS="$(sed -n 4p /tmp/_teardown_vals)"; WEST="$(sed -n 5p /tmp/_teardown_vals)"
for r in $WREPOS; do aws ecr delete-repository --repository-name "$r" --force --region "${WEST:-us-west-2}" >/dev/null 2>&1 || true; done
aws ecr put-registry-scanning-configuration --region "${WEST:-us-west-2}" --scan-type BASIC --rules '[]' >/dev/null 2>&1 || true
aws ecr put-replication-configuration --region "$REGION" --replication-configuration '{"rules":[]}' >/dev/null 2>&1 || true
aws ecr put-registry-scanning-configuration --region "$REGION" --scan-type BASIC --rules '[]' >/dev/null 2>&1 || true
exit 0
