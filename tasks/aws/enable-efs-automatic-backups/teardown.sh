#!/usr/bin/env bash
set -uo pipefail
for R in us-east-1 us-west-2; do
  for f in $(aws efs describe-file-systems --region "$R" --query "FileSystems[?Tags[?Key=='Project'&&Value=='vera2']].FileSystemId" --output text 2>/dev/null); do
    aws efs delete-file-system --file-system-id "$f" --region "$R" >/dev/null 2>&1 || true
  done
done
exit 0
