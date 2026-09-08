#!/usr/bin/env bash
# Shared application validation and transport. Callers own migrations and readiness.
# Callers set environment, release_tag, image_ref, config_file, app_secrets_file
# and app_compose; deployment.sh provides the SSH session and failure helpers.
validate_application() {
  local application=$1 environment_key=$2
  shift 2
  local secret
  local image_pattern="^ghcr\\.io/loresuelvo/$application@sha256:[a-f0-9]{64}$"
  [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "Release tag must have vX.Y.Z format."
  [[ "$image_ref" =~ $image_pattern ]] || \
    fail "Image reference is invalid."
  [[ -f "$config_file" && -s "$app_secrets_file" && -f "$app_compose" ]] || \
    fail "A deployment artifact is missing."
  grep -qx "$environment_key=$environment" "$config_file" || \
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
  for secret in "$@"; do
    grep -q "^$secret=" "$app_secrets_file" || fail "$secret is missing."
  done
  ! grep -Eq '^(DEPLOY_HOSTS|DEPLOY_SSH_PRIVATE_KEY|GHCR_USER|GHCR_TOKEN|CLOUDFLARE_ORIGIN_(CERT|KEY))=' \
    "$app_secrets_file" || fail "Deployment credentials found in application secrets."

  awk -F= '
    /^[A-Z][A-Z0-9_]*=/ {
      if (seen[$1]++) exit 1
    }
  ' "$config_file" "$app_secrets_file" || fail "Duplicate application configuration key."
}

combine_application_env() {
  local config=$1 secrets=$2 destination=$3
  {
    cat "$config"
    printf '\n'
    cat "$secrets"
    printf '\n'
  } > "$destination"
}

prepare_application_node() {
  local application=$1 host=$2 runtime_env=$3
  shift 3
  local remote="deploy@$host"
  echo "Preparing $environment node"
  scp "${ssh_options[@]}" "$runtime_env" "$remote:/etc/loresuelvo/$application/$application.env.next"
  scp "${ssh_options[@]}" "$app_compose" "$remote:/opt/loresuelvo/$application/compose.yml.next"
  ssh "${ssh_options[@]}" "$remote" bash -se -- "$application" <<'REMOTE'
application=$1
env_file=/etc/loresuelvo/$application/$application.env
compose_file=/opt/loresuelvo/$application/compose.yml
install -m 0600 "$env_file.next" "$env_file"
install -m 0640 "$compose_file.next" "$compose_file"
rm -f "$env_file.next" "$compose_file.next"
REMOTE
  printf '%s' "$GHCR_TOKEN" | ssh "${ssh_options[@]}" "$remote" \
    docker login ghcr.io --username "$GHCR_USER" --password-stdin
  ssh "${ssh_options[@]}" "$remote" bash -se -- "$application" "$image_ref" "$@" <<'REMOTE'
application=$1
export IMAGE_REF=$2
shift 2
docker compose -f "/opt/loresuelvo/$application/compose.yml" pull "$@"
REMOTE
}

record_release() {
  local application=$1 host=$2
  ssh "${ssh_options[@]}" "deploy@$host" bash -se -- "$application" "$release_tag" "$image_ref" <<'REMOTE'
marker=/opt/loresuelvo/$1/CURRENT_RELEASE
printf 'RELEASE_TAG=%s\nIMAGE_REF=%s\n' "$2" "$3" > "$marker.next"
chmod 0640 "$marker.next"
mv "$marker.next" "$marker"
REMOTE
}
