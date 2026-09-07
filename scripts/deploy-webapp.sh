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
webapp_compose="$script_root/deploy/webapp/compose.yml"

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
[[ "$image_ref" =~ ^ghcr\.io/loresuelvo/webapp@sha256:[a-f0-9]{64}$ ]] || \
  fail "Image reference is invalid."
[[ -f "$config_file" && -s "$app_secrets_file" && -f "$webapp_compose" ]] || \
  fail "A deployment artifact is missing."
grep -qx "APP_ENV=$environment" "$config_file" || \
  fail "Configuration does not match environment."

require_env DEPLOY_SSH_PRIVATE_KEY
require_env GHCR_USER
require_env GHCR_TOKEN
[[ "$GHCR_USER" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || fail "GHCR_USER is invalid."

awk '
  /^[A-Z][A-Z0-9_]*='\''[^'\'']+'\''$/ { found = 1; next }
  { exit 1 }
  END { if (!found) exit 1 }
' "$app_secrets_file" || fail "Application secrets file is invalid."
for secret in AUTH0_CLIENT_ID AUTH0_CLIENT_SECRET AUTH0_SECRET; do
  grep -q "^${secret}=" "$app_secrets_file" || fail "$secret is missing."
done
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
webapp_env="$work_dir/webapp.env"
trap 'rm -rf "$work_dir"' EXIT
umask 077

printf '%s\n' "$DEPLOY_SSH_PRIVATE_KEY" > "$ssh_key"
cp "$config_file" "$webapp_env"
{
  printf '\n'
  cat "$app_secrets_file"
  printf '\n'
} >> "$webapp_env"

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
  scp "${ssh_options[@]}" "$webapp_env" "$remote:/etc/loresuelvo/webapp/webapp.env.next"
  scp "${ssh_options[@]}" "$webapp_compose" "$remote:/opt/loresuelvo/webapp/compose.yml.next"

  ssh "${ssh_options[@]}" "$remote" 'bash -se' <<'REMOTE'
install -m 0600 /etc/loresuelvo/webapp/webapp.env.next /etc/loresuelvo/webapp/webapp.env
install -m 0640 /opt/loresuelvo/webapp/compose.yml.next /opt/loresuelvo/webapp/compose.yml
rm -f /etc/loresuelvo/webapp/webapp.env.next /opt/loresuelvo/webapp/compose.yml.next
REMOTE

  printf '%s' "$GHCR_TOKEN" | ssh "${ssh_options[@]}" "$remote" \
    docker login ghcr.io --username "$GHCR_USER" --password-stdin
  ssh "${ssh_options[@]}" "$remote" bash -se -- "$image_ref" <<'REMOTE'
export IMAGE_REF=$1
docker compose -f /opt/loresuelvo/webapp/compose.yml pull loresuelvo
REMOTE
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
  ssh "${ssh_options[@]}" "deploy@$host" bash -se -- "$release_tag" "$image_ref" <<'REMOTE'
marker=/opt/loresuelvo/webapp/CURRENT_RELEASE.next
printf 'RELEASE_TAG=%s\nIMAGE_REF=%s\n' "$1" "$2" > "$marker"
chmod 0640 "$marker"
mv "$marker" /opt/loresuelvo/webapp/CURRENT_RELEASE
REMOTE
done

echo "$environment deployment completed successfully."
