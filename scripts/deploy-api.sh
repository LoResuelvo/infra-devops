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
api_compose="$script_root/deploy/api/compose.yml"
gateway_compose="$script_root/deploy/gateway/compose.yml"
nginx_config="$script_root/deploy/gateway/nginx/default.conf"

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
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail "Release tag must have vX.Y.Z format."
[[ "$image_ref" =~ ^ghcr\.io/loresuelvo/api@sha256:[a-f0-9]{64}$ ]] || \
  fail "Image reference is invalid."
[[ -f "$config_file" && -s "$app_secrets_file" && -f "$api_compose" && \
  -f "$gateway_compose" && -f "$nginx_config" ]] || \
  fail "A deployment artifact is missing."
grep -qx "ENVIRONMENT=$environment" "$config_file" || \
  fail "Configuration does not match environment."

require_env DEPLOY_SSH_PRIVATE_KEY
require_env GHCR_USER
require_env GHCR_TOKEN
require_env CLOUDFLARE_ORIGIN_CERT
require_env CLOUDFLARE_ORIGIN_KEY
[[ "$GHCR_USER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || fail "GHCR_USER is invalid."

awk '
  /^[A-Z][A-Z0-9_]*='\''[^'\'']+'\''$/ { found = 1; next }
  { exit 1 }
  END { if (!found) exit 1 }
' "$app_secrets_file" || fail "Application secrets file is invalid."
grep -q "^DATABASE_URL=" "$app_secrets_file" || fail "DATABASE_URL is missing."
! grep -Eq '^(DEPLOY_HOSTS|DEPLOY_SSH_PRIVATE_KEY|GHCR_USER|GHCR_TOKEN|CLOUDFLARE_ORIGIN_(CERT|KEY))=' \
  "$app_secrets_file" || fail "Deployment credentials found in application secrets."

awk -F= '
  /^[A-Z][A-Z0-9_]*=/ {
    if (seen[$1]++) exit 1
  }
' "$config_file" "$app_secrets_file" || fail "Duplicate application configuration key."

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

work_dir=$(mktemp -d)
ssh_key="$work_dir/deploy_key"
api_env="$work_dir/api.env"
origin_cert="$work_dir/origin.crt"
origin_key="$work_dir/origin.key"
trap 'rm -rf "$work_dir"' EXIT
umask 077

printf '%s\n' "$DEPLOY_SSH_PRIVATE_KEY" > "$ssh_key"
printf '%s\n' "$CLOUDFLARE_ORIGIN_CERT" > "$origin_cert"
printf '%s\n' "$CLOUDFLARE_ORIGIN_KEY" > "$origin_key"
cp "$config_file" "$api_env"
{
  printf '\n'
  cat "$app_secrets_file"
  printf '\n'
} >> "$api_env"

ssh_options=(
  -i "$ssh_key"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=15
)

for host in "${hosts[@]}"; do
  remote="deploy@$host"
  echo "Preparing $environment node"
  ssh "${ssh_options[@]}" "$remote" \
    'mkdir -p /opt/loresuelvo/gateway/nginx && chmod 0750 /opt/loresuelvo/gateway/nginx'
  scp "${ssh_options[@]}" "$api_env" "$remote:/etc/loresuelvo/api/api.env.next"
  scp "${ssh_options[@]}" "$api_compose" "$remote:/opt/loresuelvo/api/compose.yml.next"
  scp "${ssh_options[@]}" "$gateway_compose" "$remote:/opt/loresuelvo/gateway/compose.yml.next"
  scp "${ssh_options[@]}" "$nginx_config" "$remote:/opt/loresuelvo/gateway/nginx/default.conf.next"
  scp "${ssh_options[@]}" "$origin_cert" "$remote:/etc/loresuelvo/gateway/tls/origin.crt.next"
  scp "${ssh_options[@]}" "$origin_key" "$remote:/etc/loresuelvo/gateway/tls/origin.key.next"

  ssh "${ssh_options[@]}" "$remote" 'bash -se' <<'REMOTE'
install -m 0600 /etc/loresuelvo/api/api.env.next /etc/loresuelvo/api/api.env
install -m 0640 /opt/loresuelvo/api/compose.yml.next /opt/loresuelvo/api/compose.yml
install -m 0640 /opt/loresuelvo/gateway/compose.yml.next /opt/loresuelvo/gateway/compose.yml
install -m 0640 /opt/loresuelvo/gateway/nginx/default.conf.next /opt/loresuelvo/gateway/nginx/default.conf
install -m 0640 /etc/loresuelvo/gateway/tls/origin.crt.next /etc/loresuelvo/gateway/tls/origin.crt
install -m 0600 /etc/loresuelvo/gateway/tls/origin.key.next /etc/loresuelvo/gateway/tls/origin.key
rm -f /etc/loresuelvo/api/api.env.next /opt/loresuelvo/api/compose.yml.next
rm -f /opt/loresuelvo/gateway/compose.yml.next /opt/loresuelvo/gateway/nginx/default.conf.next
rm -f /etc/loresuelvo/gateway/tls/origin.crt.next /etc/loresuelvo/gateway/tls/origin.key.next
REMOTE

  printf '%s' "$GHCR_TOKEN" | ssh "${ssh_options[@]}" "$remote" \
    docker login ghcr.io --username "$GHCR_USER" --password-stdin
  ssh "${ssh_options[@]}" "$remote" bash -se -- "$image_ref" <<'REMOTE'
export IMAGE_REF=$1
docker compose -f /opt/loresuelvo/api/compose.yml pull api migrate
docker compose -f /opt/loresuelvo/gateway/compose.yml pull gateway
REMOTE
done

echo "Running the $environment migration"
ssh "${ssh_options[@]}" "deploy@${hosts[0]}" bash -se -- "$image_ref" <<'REMOTE'
export IMAGE_REF=$1
docker compose -f /opt/loresuelvo/api/compose.yml run --rm migrate
REMOTE

for host in "${hosts[@]}"; do
  echo "Deploying $environment node"
  ssh "${ssh_options[@]}" "deploy@$host" bash -se -- "$image_ref" <<'REMOTE'
export IMAGE_REF=$1
docker compose -f /opt/loresuelvo/api/compose.yml up -d --no-deps api
docker compose -f /opt/loresuelvo/gateway/compose.yml run --rm --no-deps gateway nginx -t
docker compose -f /opt/loresuelvo/gateway/compose.yml up -d --no-deps gateway
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
  ssh "${ssh_options[@]}" "deploy@$host" bash -se -- "$release_tag" "$image_ref" <<'REMOTE'
marker=/opt/loresuelvo/api/CURRENT_RELEASE.next
printf 'RELEASE_TAG=%s\nIMAGE_REF=%s\n' "$1" "$2" > "$marker"
chmod 0640 "$marker"
mv "$marker" /opt/loresuelvo/api/CURRENT_RELEASE
REMOTE
done

echo "$environment deployment completed successfully."
