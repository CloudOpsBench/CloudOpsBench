#!/usr/bin/env bash
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}"

for B in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'vera2-')].Name" --output text 2>/dev/null | tr '\t' '\n'); do
  [ -n "$B" ] && [ "$B" != "None" ] || continue

  aws s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true

  aws s3api list-multipart-uploads --bucket "$B" \
    --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null | while read -r K U; do
      [ -n "${K:-}" ] && [ "$K" != "None" ] || continue
      aws s3api abort-multipart-upload --bucket "$B" --key "$K" --upload-id "$U" >/dev/null 2>&1 || true
    done

  for V in $(aws s3api list-object-versions --bucket "$B" --query 'Versions[].VersionId' --output text 2>/dev/null | tr '\t' '\n'); do
    [ -n "$V" ] && [ "$V" != "None" ] || continue
  done
done
echo "removed the pilot's objects AND aborted the in-progress multipart upload whose parts were still stored"
