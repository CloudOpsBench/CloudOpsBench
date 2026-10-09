#!/usr/bin/env bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"

AZ_A="$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneName' --output text)"
AZ_B="$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[1].ZoneName' --output text)"

echo "== VPCs =="
PROD_VPC=$(aws ec2 create-vpc --region "$REGION" --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=prod-vpc},{Key=Project,Value=vera-net}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$PROD_VPC" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$PROD_VPC" --enable-dns-hostnames '{"Value":true}'

SHARED_VPC=$(aws ec2 create-vpc --region "$REGION" --cidr-block 172.16.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=shared-vpc},{Key=Project,Value=vera-net}]' \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$SHARED_VPC" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$SHARED_VPC" --enable-dns-hostnames '{"Value":true}'

echo "== subnets =="
PROD_SUBNET_A=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$PROD_VPC" \
  --cidr-block 10.0.1.0/24 --availability-zone "$AZ_A" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=prod-subnet-a},{Key=Project,Value=vera-net}]' \
  --query 'Subnet.SubnetId' --output text)
PROD_SUBNET_B=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$PROD_VPC" \
  --cidr-block 10.0.2.0/24 --availability-zone "$AZ_B" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=prod-subnet-b},{Key=Project,Value=vera-net}]' \
  --query 'Subnet.SubnetId' --output text)
SHARED_SUBNET_A=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$SHARED_VPC" \
  --cidr-block 172.16.1.0/24 --availability-zone "$AZ_A" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=shared-subnet-a},{Key=Project,Value=vera-net}]' \
  --query 'Subnet.SubnetId' --output text)
SHARED_SUBNET_B=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$SHARED_VPC" \
  --cidr-block 172.16.2.0/24 --availability-zone "$AZ_B" \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=shared-subnet-b},{Key=Project,Value=vera-net}]' \
  --query 'Subnet.SubnetId' --output text)

echo "== VPC peering (active) =="
PEERING=$(aws ec2 create-vpc-peering-connection --region "$REGION" \
  --vpc-id "$PROD_VPC" --peer-vpc-id "$SHARED_VPC" \
  --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=prod-shared-peering},{Key=Project,Value=vera-net}]' \
  --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)
aws ec2 accept-vpc-peering-connection --region "$REGION" --vpc-peering-connection-id "$PEERING" >/dev/null

echo "== custom route tables (intentionally no cross-VPC routes yet - the bug) =="
PROD_RT=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$PROD_VPC" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=prod-custom-rt},{Key=Project,Value=vera-net}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 associate-route-table --region "$REGION" --route-table-id "$PROD_RT" --subnet-id "$PROD_SUBNET_A" >/dev/null
aws ec2 associate-route-table --region "$REGION" --route-table-id "$PROD_RT" --subnet-id "$PROD_SUBNET_B" >/dev/null

SHARED_RT=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$SHARED_VPC" \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=shared-custom-rt},{Key=Project,Value=vera-net}]' \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 associate-route-table --region "$REGION" --route-table-id "$SHARED_RT" --subnet-id "$SHARED_SUBNET_A" >/dev/null
aws ec2 associate-route-table --region "$REGION" --route-table-id "$SHARED_RT" --subnet-id "$SHARED_SUBNET_B" >/dev/null

mk_sg() {
  local vpc=$1 name=$2 role=$3 desc=${4:-$2}
  aws ec2 create-security-group --region "$REGION" --vpc-id "$vpc" \
    --group-name "$name" --description "$desc" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$name},{Key=Role,Value=$role},{Key=Project,Value=vera-net}]" \
    --query 'GroupId' --output text
}

echo "== prod-vpc security groups (10 - names scrambled from their real Role) =="
APP_SG=$(mk_sg "$PROD_VPC" prod-web-sg application-servers)        # actually the app tier
mk_sg "$PROD_VPC" prod-app-sg web-frontend          >/dev/null
mk_sg "$PROD_VPC" prod-db-sg cache-layer            >/dev/null
mk_sg "$PROD_VPC" prod-cache-sg background-workers  >/dev/null
mk_sg "$PROD_VPC" prod-worker-sg scheduler          >/dev/null
mk_sg "$PROD_VPC" prod-api-sg monitoring            >/dev/null
mk_sg "$PROD_VPC" prod-monitoring-sg log-aggregation >/dev/null
mk_sg "$PROD_VPC" prod-logging-sg admin-bastion     >/dev/null
mk_sg "$PROD_VPC" prod-admin-sg legacy-service      >/dev/null
mk_sg "$PROD_VPC" prod-legacy-sg external-partners  >/dev/null

echo "== shared-vpc security groups (5) =="
SHARED_RDS_SG=$(mk_sg "$SHARED_VPC" shared-rds-sg primary-database "Primary RDS database (PostgreSQL, port 5432)") # intentionally no 5432 inbound
mk_sg "$SHARED_VPC" shared-replica-sg read-replica  >/dev/null
mk_sg "$SHARED_VPC" shared-cache-sg elasticache     >/dev/null
mk_sg "$SHARED_VPC" shared-search-sg opensearch     >/dev/null
mk_sg "$SHARED_VPC" shared-storage-sg efs-storage   >/dev/null

python3 - "$PROD_VPC" "$SHARED_VPC" "$PEERING" "$PROD_RT" "$SHARED_RT" "$APP_SG" "$SHARED_RDS_SG" <<'PY'
import json, sys
keys = ["prod_vpc_id", "shared_vpc_id", "peering_id", "prod_rt_id", "shared_rt_id",
        "app_sg_id", "shared_rds_sg_id"]
json.dump(dict(zip(keys, sys.argv[1:])), open("seed_state.json", "w"), indent=2)
PY
echo "setup complete: prod=$PROD_VPC shared=$SHARED_VPC peering=$PEERING"
