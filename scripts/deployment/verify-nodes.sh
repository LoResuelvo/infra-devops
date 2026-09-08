#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 ENVIRONMENT HOSTS" >&2
  exit 2
fi
environment=$1
hosts_input=$2
script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$script_root/scripts/lib/deployment.sh"
validate_environment "$environment"
parse_hosts "$hosts_input"
prepare_ssh

config_name=staging
[[ "$environment" != production ]] || config_name=prod
gateway_config="$script_root/deploy/gateway/config/$config_name.conf"
api_name=$(sed -n 's/^API_SERVER_NAMES=//p' "$gateway_config")
web_name=$(sed -n 's/^WEB_SERVER_NAMES=\([^ ]*\).*/\1/p' "$gateway_config")
admin_name=$(sed -n 's/^ADMIN_SERVER_NAMES=\([^ ]*\).*/\1/p' "$gateway_config")

for host in "${hosts[@]}"; do
  ssh "${ssh_options[@]}" "deploy@$host" bash -se -- "$api_name" "$web_name" "$admin_name" <<'REMOTE'
set -euo pipefail
api_name=$1 web_name=$2 admin_name=$3
compose_api=/opt/loresuelvo/api/compose.yml
compose_web=/opt/loresuelvo/webapp/compose.yml
compose_gateway=/opt/loresuelvo/gateway/compose.yml
docker compose -f "$compose_gateway" ps --status running gateway | grep -q nginx-proxy
docker compose -f "$compose_api" ps --status running api | grep -q api
docker compose -f "$compose_web" ps --status running loresuelvo | grep -q loresuelvo
curl --fail --silent --show-error http://127.0.0.1:8080/health/ready >/dev/null
curl --fail --silent --show-error --insecure --noproxy '*' \
  --resolve "$web_name:443:127.0.0.1" "https://$web_name/" >/dev/null
docker exec nginx-proxy nginx -T 2>&1 | grep -F "server_name $admin_name;" >/dev/null
status=$(curl --silent --show-error --insecure --noproxy '*' --output /dev/null \
  --write-out '%{http_code}' --resolve "$api_name:443:127.0.0.1" \
  "https://$api_name/__gateway_ready")
[[ "$status" == 404 ]]
REMOTE
done
echo "$environment nodes passed gateway, API, Web App, and Admin route checks."
