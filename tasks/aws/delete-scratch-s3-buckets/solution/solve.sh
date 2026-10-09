#!/usr/bin/env bash
# Delete every vera2- bucket: general-purpose buckets from list-buckets and
# S3 Express directory buckets from list-directory-buckets.
set -uo pipefail
REGION="us-east-1"
DELETED=""
RC=0

for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'vera2-')].Name" --output text); do
  if aws s3 rb "s3://$b" --force >/dev/null 2>&1 \
     || aws s3api delete-bucket --bucket "$b" --region "$REGION" >/dev/null 2>&1; then
    DELETED="${DELETED} general:${b}"
  else
    echo "ERROR: failed to delete general-purpose bucket $b" >&2
    RC=1
  fi
done

for b in $(aws s3api list-directory-buckets --region "$REGION" \
             --query "Buckets[?starts_with(Name,'vera2-')].Name" --output text); do
  if aws s3api delete-bucket --bucket "$b" --region "$REGION" >/dev/null 2>&1; then
    DELETED="${DELETED} directory:${b}"
  else
    echo "ERROR: failed to delete directory bucket $b" >&2
    RC=1
  fi
done

[ "$RC" -eq 0 ] || { echo "aborted: at least one bucket deletion failed"; exit 1; }
echo "deleted:${DELETED:-  none}"
exit 0
