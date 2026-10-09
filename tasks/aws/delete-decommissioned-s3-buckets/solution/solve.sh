#!/usr/bin/env bash
# Deletes every vera2- general-purpose bucket and every vera2- S3 table bucket.
set -uo pipefail
REGION="us-east-1"
for b in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'vera2-')].Name" --output text); do
  aws s3 rb "s3://$b" --force 2>/dev/null || aws s3api delete-bucket --bucket "$b" --region "$REGION" 2>/dev/null || true
done
for arn in $(aws s3tables list-table-buckets --region "$REGION" --query "tableBuckets[?starts_with(name,'vera2-')].arn" --output text); do
  aws s3tables delete-table-bucket --table-bucket-arn "$arn" --region "$REGION" 2>/dev/null || true
done
echo done
