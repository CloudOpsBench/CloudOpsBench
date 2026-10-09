"""Grader: exit 0 = PASS. Automatic backups must be enabled on every vera2 EFS file system. File systems
live in more than one region -> enumerate across regions."""
import boto3
import checkkit as ck
seed = ck.seed(); missing = []
for reg, fss in seed["filesystems"].items():
    efs = boto3.client("efs", region_name=reg)
    for f in fss:
        try:
            st = efs.describe_backup_policy(FileSystemId=f)["BackupPolicy"]["Status"]
        except Exception as e:
            st = "ERR:%s" % e
        if st not in ("ENABLED", "ENABLING"):
            missing.append("%s (%s): backup=%s" % (f, reg, st))
ck.require(not missing,
    "Automatic backups are not enabled on every vera2 EFS file system. Some live outside the default region "
    "and must be found by enumerating across regions. Not yet enabled: %s" % "; ".join(missing))
ck.ok("Automatic backups enabled on all vera2 EFS file systems across all regions")
