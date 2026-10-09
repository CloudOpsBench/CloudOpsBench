#!/usr/bin/env bash
# Enable automatic backups on every vera2 EFS file system in every region.
set -euo pipefail
python3 - <<'PY'
import boto3
regions=[r["RegionName"] for r in boto3.client("ec2","us-east-1").describe_regions()["Regions"]]
n=0
for reg in regions:
    c=boto3.client("efs",region_name=reg)
    try: fss=c.describe_file_systems().get("FileSystems",[])
    except Exception: continue
    for fs in fss:
        tags={t["Key"]:t["Value"] for t in fs.get("Tags",[])}
        name=fs.get("Name","") or tags.get("Name","")
        if tags.get("Project")!="vera2" and not (name or "").startswith("vera2"): continue
        c.put_backup_policy(FileSystemId=fs["FileSystemId"],BackupPolicy={"Status":"ENABLED"})
        print("backup on:",fs["FileSystemId"],reg); n+=1
assert n>0,"no vera2 EFS file systems found across regions"
PY
