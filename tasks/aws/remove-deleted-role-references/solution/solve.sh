#!/usr/bin/env bash
# Deletes the inline policy that names the retired role and disassociates the
# account's Greengrass service role when it still points at that role.
set -uo pipefail
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"

python3 - <<'PY'
import json, os, subprocess, sys

REGION = os.environ.get("AWS_REGION", "us-east-1")
RETIRED = "vera2-fleet-telemetry-role"

def aws(*args, soft=False):
    cmd = ["aws", "--region", REGION, "--output", "json"] + list(args)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        if soft:
            return None
        sys.exit("solution: %s failed: %s" % (" ".join(args[:3]), proc.stderr.strip()[-400:]))
    return json.loads(proc.stdout) if proc.stdout.strip() else {}

if aws("iam", "delete-role-policy", "--role-name", "vera2-fleet-ops-role",
       "--policy-name", "legacy-telemetry-access", soft=True) is None:
    print("solution: the inline policy naming %s was already absent" % RETIRED)
else:
    print("solution: removed the inline policy on vera2-fleet-ops-role that named %s" % RETIRED)

current = aws("greengrassv2", "get-service-role-for-account", soft=True)
arn = (current or {}).get("roleArn")
print("solution: account service-role association -> %s" % (arn or "(none)"))
if arn and arn.rsplit("/", 1)[-1] == RETIRED:
    aws("greengrassv2", "disassociate-service-role-from-account")
    print("solution: disassociated the service role, which was the last thing naming %s" % RETIRED)
else:
    print("solution: the association does not name %s" % RETIRED)
PY
