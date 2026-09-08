#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 6 || $# -gt 7 ]]; then
  echo "usage: $0 ENVIRONMENT HOSTS IMAGE_REF RELEASE_TAG CONFIG_FILE SECRETS_FILE [deploy|hydrate]" >&2
  exit 2
fi

environment=$1
hosts_input=$2
image_ref=$3
release_tag=$4
config_file=$5
app_secrets_file=$6
deployment_mode=${7:-deploy}
script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
app_compose="$script_root/deploy/api/compose.yml"

source "$script_root/scripts/lib/deployment.sh"
source "$script_root/scripts/lib/application-deployment.sh"

validate_environment "$environment"
[[ "$deployment_mode" == deploy || "$deployment_mode" == hydrate ]] || fail "Deployment mode must be deploy or hydrate."
validate_application api ENVIRONMENT DATABASE_URL
parse_hosts "$hosts_input"
prepare_ssh
runtime_env="$work_dir/api.env"
combine_application_env "$config_file" "$app_secrets_file" "$runtime_env"

pull_services=(api)
[[ "$deployment_mode" != deploy ]] || pull_services+=(migrate)
for host in "${hosts[@]}"; do
  prepare_application_node api "$host" "$runtime_env" "${pull_services[@]}"
done

if [[ "$deployment_mode" == deploy ]]; then
  echo "Running the $environment migration"
  ssh "${ssh_options[@]}" "deploy@${hosts[0]}" bash -se -- "$image_ref" <<'REMOTE'
export IMAGE_REF=$1
docker compose -f /opt/loresuelvo/api/compose.yml run --rm migrate
REMOTE
fi

for host in "${hosts[@]}"; do
  echo "Deploying $environment node"
  ssh "${ssh_options[@]}" "deploy@$host" bash -se -- "$image_ref" <<'REMOTE'
export IMAGE_REF=$1
docker compose -f /opt/loresuelvo/api/compose.yml up -d --no-deps api
for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error http://127.0.0.1:8080/health/ready >/dev/null; then
    exit 0
  fi
  sleep 2
done
echo "API readiness check failed." >&2
exit 1
REMOTE
done

for host in "${hosts[@]}"; do
  record_release api "$host"
done

echo "$environment deployment completed successfully."
