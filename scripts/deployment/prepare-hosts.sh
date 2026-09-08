#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 ENVIRONMENT OUTPUT_FILE" >&2
  exit 2
fi
environment=$1
output_file=$2
[[ "$environment" == staging || "$environment" == production ]] || {
  echo "Environment must be staging or production." >&2
  exit 2
}
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"

script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
terraform_root="$script_root/terraform/environments/$environment/replicas"
bucket="loresuelvo-terraform-state-$environment"

export AWS_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
export AWS_ENDPOINT_URL_S3=$R2_ENDPOINT
terraform -chdir="$terraform_root" init -input=false -reconfigure \
  -backend-config="bucket=$bucket" >/dev/null
"$script_root/scripts/deployment/terraform-hosts.sh" "$terraform_root" "$output_file"
