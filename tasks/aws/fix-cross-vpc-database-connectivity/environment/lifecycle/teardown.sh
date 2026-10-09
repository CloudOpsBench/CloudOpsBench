#!/usr/bin/env bash
# Optional. A lane nuke resets cloud state after every run, so this is a courtesy best-effort
# cleanup - never fail the run on cleanup trouble.
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"

field() { python3 -c "import json;print(json.load(open('seed_state.json')).get('$1',''))" 2>/dev/null; }
PEERING="$(field peering_id)"
PROD_VPC="$(field prod_vpc_id)"
SHARED_VPC="$(field shared_vpc_id)"

[ -n "$PEERING" ] && aws ec2 delete-vpc-peering-connection --region "$REGION" \
  --vpc-peering-connection-id "$PEERING" >/dev/null 2>&1

delete_vpc_stack() {
  local vpc=$1
  [ -z "$vpc" ] && return 0
  for sg in $(aws ec2 describe-security-groups --region "$REGION" --filters "Name=vpc-id,Values=$vpc" \
      --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1
  done
  for rt in $(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$vpc" \
      --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null); do
    for assoc in $(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$rt" \
        --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null); do
      aws ec2 disassociate-route-table --region "$REGION" --association-id "$assoc" >/dev/null 2>&1
    done
    aws ec2 delete-route-table --region "$REGION" --route-table-id "$rt" >/dev/null 2>&1
  done
  for subnet in $(aws ec2 describe-subnets --region "$REGION" --filters "Name=vpc-id,Values=$vpc" \
      --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
    aws ec2 delete-subnet --region "$REGION" --subnet-id "$subnet" >/dev/null 2>&1
  done
  aws ec2 delete-vpc --region "$REGION" --vpc-id "$vpc" >/dev/null 2>&1
}

delete_vpc_stack "$PROD_VPC"
delete_vpc_stack "$SHARED_VPC"

exit 0
