#!/usr/bin/env bash
# Reference fix. Discovers everything at runtime; never reads seed_state.json.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"

# Discover the team's repositories by their tag, then split off the upstream mirror by name.
APPS=()
MIRROR=""
for r in $(aws ecr describe-repositories --region "$REGION" --query 'repositories[].repositoryName' --output text); do
  arn="arn:aws:ecr:${REGION}:${ACCT}:repository/${r}"
  aws ecr list-tags-for-resource --resource-arn "$arn" --region "$REGION" \
    --query "length(tags[?Key=='Project' && Value=='scanpolicy-demo'])" --output text 2>/dev/null | grep -qx 1 || continue
  case "$r" in
    mirror-upstream-cache-*) MIRROR="$r" ;;
    *) APPS+=("$r") ;;
  esac
done
[ "${#APPS[@]}" -gt 0 ] || { echo "no application repositories found" >&2; exit 1; }
echo "application repositories: ${APPS[*]}  (mirror: ${MIRROR:-none})"

aws ecr put-registry-scanning-configuration --region "$REGION" --scan-type BASIC   --rules "$(python3 - "$REGION" "$MIRROR" "${APPS[@]}" <<'PY'
import fnmatch, json, sys, boto3
region, mirror, apps = sys.argv[1], sys.argv[2], sys.argv[3:]
ecr = boto3.client("ecr", region_name=region)
ours = set(apps) | {mirror}
everything = [r["repositoryName"] for pg in ecr.get_paginator("describe_repositories").paginate()
              for r in pg["repositories"]]
keep = []
for rule in ecr.get_registry_scanning_configuration()["scanningConfiguration"]["rules"]:
    if rule.get("scanFrequency") != "SCAN_ON_PUSH":
        continue
    for f in rule.get("repositoryFilters", []):
        pat = f["filter"]
        covers = [r for r in everything
                  if fnmatch.fnmatchcase(r, pat) or fnmatch.fnmatchcase(r, pat + "*")]
        if any(r not in ours for r in covers) and mirror not in covers:
            keep.append(pat)
filters = keep + [a for a in apps if a not in keep]
print(json.dumps([{"scanFrequency": "SCAN_ON_PUSH",
                   "repositoryFilters": [{"filter": f, "filterType": "WILDCARD"} for f in filters]}]))
PY
)" >/dev/null

for W in $(aws ecr describe-registry --region "$REGION"              --query 'replicationConfiguration.rules[].destinations[].region' --output text); do
  WAPPS=""
  for r in $(aws ecr describe-repositories --region "$W" --query 'repositories[].repositoryName' --output text); do
    arn="arn:aws:ecr:${W}:${ACCT}:repository/${r}"
    aws ecr list-tags-for-resource --resource-arn "$arn" --region "$W"       --query "length(tags[?Key=='Project' && Value=='scanpolicy-demo'])" --output text 2>/dev/null | grep -qx 1 || continue
    case "$r" in mirror-upstream-cache-*) continue ;; esac
    WAPPS="$WAPPS $r"
  done
  [ -n "$WAPPS" ] || continue
  echo "second registry $W: $WAPPS"
  aws ecr put-registry-scanning-configuration --region "$W" --scan-type BASIC   --rules "$(python3 - $WAPPS <<'PYW'
import json,sys
print(json.dumps([{"scanFrequency":"SCAN_ON_PUSH",
                   "repositoryFilters":[{"filter":r,"filterType":"WILDCARD"} for r in sys.argv[1:]]}]))
PYW
)" >/dev/null
done


# Widen the findings-routing rule so it forwards scans for every repository, not just one.
TOPIC_ARN="$(aws sns list-topics --region "$REGION" --query "Topics[?contains(TopicArn,':sec-scan-findings-')].TopicArn | [0]" --output text)"
[ -n "$TOPIC_ARN" ] && [ "$TOPIC_ARN" != "None" ] || { echo "security topic not found" >&2; exit 1; }

for rl in $(aws events list-rules --region "$REGION" --query 'Rules[].Name' --output text); do
  aws events list-targets-by-rule --rule "$rl" --region "$REGION" --query 'Targets[].Arn' --output text 2>/dev/null \
    | grep -qF "$TOPIC_ARN" || continue
  aws events put-rule --name "$rl" --region "$REGION" --state ENABLED \
    --event-pattern '{"source":["aws.ecr"],"detail-type":["ECR Image Scan"]}' >/dev/null
  echo "widened routing rule $rl"
done
echo done
