#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "usage: $0 ENVIRONMENT HOSTS IMAGE_REF RELEASE_TAG CONFIG_FILE SECRETS_FILE" >&2
  exit 2
fi

environment=$1
hosts_input=$2
image_ref=$3
release_tag=$4
config_file=$5
app_secrets_file=$6
script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app_compose="$script_root/deploy/webapp/compose.yml"

source "$script_root/scripts/lib/deployment.sh"
source "$script_root/scripts/lib/application-deployment.sh"

validate_environment "$environment"
validate_application webapp APP_ENV AUTH0_CLIENT_ID AUTH0_CLIENT_SECRET AUTH0_SECRET
parse_hosts "$hosts_input"
prepare_ssh
runtime_env="$work_dir/webapp.env"
combine_application_env "$config_file" "$app_secrets_file" "$runtime_env"

for host in "${hosts[@]}"; do
  prepare_application_node webapp "$host" "$runtime_env" loresuelvo
done

for host in "${hosts[@]}"; do
  echo "Deploying $environment node"
  ssh "${ssh_options[@]}" "deploy@$host" bash -se -- "$image_ref" <<'REMOTE'
export IMAGE_REF=$1
compose_file=/opt/loresuelvo/webapp/compose.yml
docker compose -f "$compose_file" up -d --no-deps loresuelvo
for attempt in $(seq 1 30); do
  container_id=$(docker compose -f "$compose_file" ps -q loresuelvo)
  if [[ -n "$container_id" ]] && \
    [[ "$(docker inspect --format '{{.State.Health.Status}}' "$container_id")" == "healthy" ]]; then
    exit 0
  fi
  sleep 2
done
echo "Web App healthcheck failed." >&2
docker compose -f "$compose_file" ps loresuelvo >&2
exit 1
REMOTE
done

for host in "${hosts[@]}"; do
  record_release webapp "$host"
done

echo "$environment deployment completed successfully."
