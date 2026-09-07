#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 ENVIRONMENT HOSTS" >&2
  exit 2
fi

environment=$1
hosts_input=$2
script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gateway_compose="$script_root/deploy/gateway/compose.yml"
nginx_template="$script_root/deploy/gateway/nginx/default.conf.template"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_env() {
  local name=$1
  [[ -n "${!name-}" ]] || fail "Required variable $name is missing."
}

[[ "$environment" == "staging" || "$environment" == "production" ]] || \
  fail "Environment must be staging or production."
[[ -f "$gateway_compose" && -f "$nginx_template" ]] || \
  fail "A gateway deployment artifact is missing."

require_env DEPLOY_SSH_PRIVATE_KEY
require_env CLOUDFLARE_ORIGIN_CERT
require_env CLOUDFLARE_ORIGIN_KEY

normalized_hosts=${hosts_input//,/ }
normalized_hosts=${normalized_hosts//$'\n'/ }
read -r -a hosts <<< "$normalized_hosts"
[[ ${#hosts[@]} -gt 0 ]] || fail "At least one deployment host is required."

declare -A seen_hosts=()
for host in "${hosts[@]}"; do
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "Deployment host is invalid."
  [[ -z "${seen_hosts[$host]-}" ]] || fail "Deployment hosts must be unique."
  seen_hosts[$host]=1
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::add-mask::%s\n' "$host"
  fi
done

case "$environment" in
  staging)
    api_server_name="api-test.loresuelvo.com.ar"
    web_server_names="test.loresuelvo.com.ar"
    admin_server_names="gestion-test.loresuelvo.com.ar"
    ;;
  production)
    api_server_name="api.loresuelvo.com.ar"
    web_server_names="loresuelvo.com.ar www.loresuelvo.com.ar"
    admin_server_names="gestion.loresuelvo.com.ar"
    ;;
esac

work_dir=$(mktemp -d)
ssh_key="$work_dir/deploy_key"
nginx_config="$work_dir/default.conf"
origin_cert="$work_dir/origin.crt"
origin_key="$work_dir/origin.key"
trap 'rm -rf "$work_dir"' EXIT
umask 077

sed \
  -e "s/__API_SERVER_NAMES__/$api_server_name/g" \
  -e "s/__WEB_SERVER_NAMES__/$web_server_names/g" \
  -e "s/__ADMIN_SERVER_NAMES__/$admin_server_names/g" \
  "$nginx_template" > "$nginx_config"
! grep -q '__[A-Z_]*__' "$nginx_config" || fail "Gateway template is incomplete."

printf '%s\n' "$DEPLOY_SSH_PRIVATE_KEY" > "$ssh_key"
printf '%s\n' "$CLOUDFLARE_ORIGIN_CERT" > "$origin_cert"
printf '%s\n' "$CLOUDFLARE_ORIGIN_KEY" > "$origin_key"

ssh_options=(
  -i "$ssh_key"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

for host in "${hosts[@]}"; do
  remote="deploy@$host"
  echo "Preparing $environment gateway node"
  ssh "${ssh_options[@]}" "$remote" \
    'mkdir -p /opt/loresuelvo/gateway/nginx && chmod 0750 /opt/loresuelvo/gateway/nginx'
  scp "${ssh_options[@]}" "$gateway_compose" "$remote:/opt/loresuelvo/gateway/compose.yml.next"
  scp "${ssh_options[@]}" "$nginx_config" "$remote:/opt/loresuelvo/gateway/nginx/default.conf.next"
  scp "${ssh_options[@]}" "$origin_cert" "$remote:/etc/loresuelvo/gateway/tls/origin.crt.next"
  scp "${ssh_options[@]}" "$origin_key" "$remote:/etc/loresuelvo/gateway/tls/origin.key.next"

  ssh "${ssh_options[@]}" "$remote" 'bash -se' <<'REMOTE'
install -m 0640 /opt/loresuelvo/gateway/compose.yml.next /opt/loresuelvo/gateway/compose.yml
install -m 0640 /opt/loresuelvo/gateway/nginx/default.conf.next /opt/loresuelvo/gateway/nginx/default.conf
install -m 0640 /etc/loresuelvo/gateway/tls/origin.crt.next /etc/loresuelvo/gateway/tls/origin.crt
install -m 0600 /etc/loresuelvo/gateway/tls/origin.key.next /etc/loresuelvo/gateway/tls/origin.key
rm -f /opt/loresuelvo/gateway/compose.yml.next /opt/loresuelvo/gateway/nginx/default.conf.next
rm -f /etc/loresuelvo/gateway/tls/origin.crt.next /etc/loresuelvo/gateway/tls/origin.key.next
docker compose -f /opt/loresuelvo/gateway/compose.yml pull gateway
docker compose -f /opt/loresuelvo/gateway/compose.yml run --rm --no-deps gateway nginx -t
docker compose -f /opt/loresuelvo/gateway/compose.yml up -d --no-deps --force-recreate gateway
docker inspect nginx-proxy --format '{{.State.Running}}' | grep -qx true
docker compose -f /opt/loresuelvo/gateway/compose.yml ps gateway
REMOTE

  echo "Checking $environment gateway node"
  ssh "${ssh_options[@]}" "$remote" bash -se -- "$api_server_name" <<'REMOTE'
api_server_name=$1
response_body=$(mktemp)
trap 'rm -f "$response_body"' EXIT
ready=false
for attempt in $(seq 1 30); do
  status=$(curl --silent --show-error --insecure --noproxy '*' \
    --output "$response_body" --write-out '%{http_code}' \
    --resolve "$api_server_name:443:127.0.0.1" \
    "https://$api_server_name/__gateway_ready") || status=000
  if [[ "$status" == 404 ]] && grep -qx 'loresuelvo gateway ready' "$response_body"; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  docker logs --tail 100 nginx-proxy >&2 || true
  echo "Gateway self-check failed: expected custom 404 response." >&2
  exit 1
fi
REMOTE
done

echo "$environment gateway deployment completed successfully."
