#!/usr/bin/env bash
# Adds the peering routes in both route tables and allows TCP 5432 from the
# prod-vpc CIDR on the primary database security group.
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"

python3 - "$REGION" <<'PY'
import sys
import boto3
from botocore.exceptions import ClientError

reg = sys.argv[1]
ec2 = boto3.client("ec2", region_name=reg)

def vpc_by_name(name):
    vpcs = ec2.describe_vpcs(Filters=[{"Name": "tag:Name", "Values": [name]}])["Vpcs"]
    assert vpcs, f"no VPC named {name} in {reg}"
    return vpcs[0]

prod = vpc_by_name("prod-vpc")
shared = vpc_by_name("shared-vpc")
PROD_VPC, SHARED_VPC = prod["VpcId"], shared["VpcId"]
PROD_CIDR = prod["CidrBlock"]
SHARED_CIDR = shared["CidrBlock"]

def custom_rt(vpc_id):
    # The subnets are associated with a custom (non-main) route table; pick that one.
    rts = ec2.describe_route_tables(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["RouteTables"]
    custom = [rt for rt in rts
              if not any(a.get("Main") for a in rt.get("Associations", []))]
    assert custom, f"no custom route table in {vpc_id}"
    return custom[0]["RouteTableId"]

PROD_RT = custom_rt(PROD_VPC)
SHARED_RT = custom_rt(SHARED_VPC)

# The active peering connection linking the two VPCs.
peerings = ec2.describe_vpc_peering_connections(Filters=[
    {"Name": "status-code", "Values": ["active"]}])["VpcPeeringConnections"]
peer = None
for p in peerings:
    ids = {p["RequesterVpcInfo"]["VpcId"], p["AccepterVpcInfo"]["VpcId"]}
    if ids == {PROD_VPC, SHARED_VPC}:
        peer = p
        break
assert peer, "no active peering connection between prod-vpc and shared-vpc"
PEERING = peer["VpcPeeringConnectionId"]

# The primary database SG in shared-vpc, identified by its Role tag
# (Role=primary-database) rather than by name.
sgs = ec2.describe_security_groups(Filters=[
    {"Name": "vpc-id", "Values": [SHARED_VPC]},
    {"Name": "tag:Role", "Values": ["primary-database"]}])["SecurityGroups"]
assert sgs, "no primary-database security group found in shared-vpc"
SHARED_RDS_SG = sgs[0]["GroupId"]

print(f"discovered prod={PROD_VPC}({PROD_CIDR}) shared={SHARED_VPC}({SHARED_CIDR}) "
      f"peering={PEERING} prod_rt={PROD_RT} shared_rt={SHARED_RT} rds_sg={SHARED_RDS_SG}")

def add_route(rt_id, dest_cidr):
    try:
        ec2.create_route(RouteTableId=rt_id, DestinationCidrBlock=dest_cidr,
                         VpcPeeringConnectionId=PEERING)
    except ClientError as e:
        if e.response["Error"]["Code"] != "RouteAlreadyExists":
            raise

# prod -> shared route
add_route(PROD_RT, SHARED_CIDR)
# shared -> prod return route (peering routes are needed in both directions)
add_route(SHARED_RT, PROD_CIDR)

# Allow the application tier to reach the primary database on 5432. Scoped to the prod VPC CIDR
# rather than a cross-VPC security-group reference: same effect, without depending on VPC-peering
# security-group referencing being enabled on this connection.
try:
    ec2.authorize_security_group_ingress(
        GroupId=SHARED_RDS_SG,
        IpPermissions=[{
            "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
            "IpRanges": [{"CidrIp": PROD_CIDR}]}])
except ClientError as e:
    if e.response["Error"]["Code"] != "InvalidPermission.Duplicate":
        raise

print("solution complete")
PY
