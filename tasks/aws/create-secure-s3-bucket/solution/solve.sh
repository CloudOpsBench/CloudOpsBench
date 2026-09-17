#!/bin/bash
set -euo pipefail

echo 'TODO: reference solution blocked until trusted emulator-only Terraform provider configuration and isolation are implemented.' >&2
exit 2

# Intended flow after integration and removal of the guard above:
# TODO: provision trusted provider configuration separately; never use default AWS.
cd /workspace
cp /solution/main.tf /workspace/main.tf
terraform init -input=false
terraform validate
terraform apply -input=false -auto-approve
