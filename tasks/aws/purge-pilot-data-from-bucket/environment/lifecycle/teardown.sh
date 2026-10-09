#!/usr/bin/env bash
set -uo pipefail
for B in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'vera2-')].Name" --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$B" ] && [ "$B" != "None" ] || continue
  aws s3api list-multipart-uploads --bucket "$B" --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null | while read -r K U; do
    [ -n "${K:-}" ] && [ "$K" != "None" ] || continue
    aws s3api abort-multipart-upload --bucket "$B" --key "$K" --upload-id "$U" >/dev/null 2>&1 || true
  done
  aws s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$B" >/dev/null 2>&1 || true
done
echo "torn down: vera2- buckets, their objects and their in-progress multipart uploads"
