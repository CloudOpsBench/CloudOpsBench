"""Grader: exit 0 = PASS, non-zero = FAIL. Runs against REAL AWS on the lane, in the same
directory setup ran in (so ./seed_state.json is present). `checkkit` is provided by the
runner at grading time - you do not need to vendor it into your bundle.

Three things must all be fixed for PASS:
  1. prod-custom-rt has a route to shared-vpc via the peering connection. Without this,
     prod instances cannot initiate connections to shared-vpc.
  2. shared-custom-rt has a route to prod-vpc via the peering connection. VPC routing is
     not transitive - both sides need explicit routes, and this direction is the one
     most commonly missed (the prod->shared route alone looks like it should work).
  3. shared-rds-sg allows inbound TCP 5432 from the application tier (prod-web-sg, despite
     the misleading name - identified by its Role=application-servers tag, not its Name) or
     from the prod-vpc CIDR directly - either achieves the same connectivity.

Protected resources (must be unchanged):
  - The VPC peering connection must remain ACTIVE - recreating it is not a valid fix.
  - The subnets in both VPCs must still be associated with their custom route tables, not
    reverted to the main route table.
"""
import checkkit as ck

seed = ck.seed()
ec2 = ck.client("ec2")

prod_rt_id = seed["prod_rt_id"]
shared_rt_id = seed["shared_rt_id"]
peering_id = seed["peering_id"]
app_sg_id = seed["app_sg_id"]  # prod-web-sg (application tier - name is scrambled)
shared_rds_sg_id = seed["shared_rds_sg_id"]
prod_vpc_cidr = "10.0.0.0/16"
shared_vpc_cidr = "172.16.0.0/16"

# ---- protected: peering connection must still be active, not destroyed/recreated ----
peering = ec2.describe_vpc_peering_connections(
    VpcPeeringConnectionIds=[peering_id])["VpcPeeringConnections"][0]
ck.require(peering["Status"]["Code"] == "active",
           f"VPC peering connection {peering_id} is no longer active")

# ---- check 1: prod-custom-rt must route to shared-vpc over the peering connection ----
prod_rt = ec2.describe_route_tables(RouteTableIds=[prod_rt_id])["RouteTables"][0]
prod_has_route = any(
    r.get("DestinationCidrBlock") == shared_vpc_cidr
    and r.get("VpcPeeringConnectionId") == peering_id
    and r.get("State") == "active"
    for r in prod_rt["Routes"]
)
ck.require(prod_has_route,
           f"prod-custom-rt ({prod_rt_id}) has no active route to {shared_vpc_cidr} via "
           f"peering {peering_id} - prod instances cannot reach shared-vpc")

# ---- check 2: shared-custom-rt must have the symmetric return route ----
shared_rt = ec2.describe_route_tables(RouteTableIds=[shared_rt_id])["RouteTables"][0]
shared_has_route = any(
    r.get("DestinationCidrBlock") == prod_vpc_cidr
    and r.get("VpcPeeringConnectionId") == peering_id
    and r.get("State") == "active"
    for r in shared_rt["Routes"]
)
ck.require(shared_has_route,
           f"shared-custom-rt ({shared_rt_id}) has no active route to {prod_vpc_cidr} via "
           f"peering {peering_id} - shared-vpc cannot reply to prod instances")

# ---- check 3: shared-rds-sg must allow TCP 5432 from the application tier ----
rds_sg = ec2.describe_security_groups(GroupIds=[shared_rds_sg_id])["SecurityGroups"][0]


def allows_5432(sg):
    for rule in sg.get("IpPermissions", []):
        proto = rule.get("IpProtocol", "")
        if proto not in ("-1", "tcp"):
            continue
        if not (rule.get("FromPort", 0) <= 5432 <= rule.get("ToPort", 65535)):
            continue
        if any(pair.get("GroupId") == app_sg_id for pair in rule.get("UserIdGroupPairs", [])):
            return True
        if any(r["CidrIp"] == prod_vpc_cidr for r in rule.get("IpRanges", [])):
            return True
    return False


ck.require(allows_5432(rds_sg),
           "shared-rds-sg has no inbound rule allowing TCP 5432 from the application-tier "
           "security group (prod-web-sg) or from 10.0.0.0/16 - the database is still "
           "unreachable from prod")

# ---- protected: subnet-route-table associations must be unchanged ----
def subnet_ids(name):
    return [s["SubnetId"] for s in ec2.describe_subnets(
        Filters=[{"Name": "tag:Name", "Values": [name]}])["Subnets"]]


def still_associated(name, expected_rt_id):
    ids = subnet_ids(name)
    if not ids:
        return False
    rts = ec2.describe_route_tables(
        Filters=[{"Name": "association.subnet-id", "Values": ids}])["RouteTables"]
    return any(rt["RouteTableId"] == expected_rt_id for rt in rts)


for name in ("prod-subnet-a", "prod-subnet-b"):
    ck.require(still_associated(name, prod_rt_id), f"{name} is no longer associated with prod-custom-rt")
for name in ("shared-subnet-a", "shared-subnet-b"):
    ck.require(still_associated(name, shared_rt_id), f"{name} is no longer associated with shared-custom-rt")

ck.ok("prod-custom-rt routes to shared-vpc, shared-custom-rt routes back to prod-vpc, and "
      "shared-rds-sg allows TCP 5432 from the application tier")
