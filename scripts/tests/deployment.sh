#!/usr/bin/env bash
# Offline orchestration regression checks; never connects to deployment hosts.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export TEST_LOG="$test_dir/events"
export DEPLOY_SSH_PRIVATE_KEY=fixture GHCR_USER=fixture GHCR_TOKEN=fixture
export CLOUDFLARE_ORIGIN_CERT=fixture CLOUDFLARE_ORIGIN_KEY=fixture

ssh() {
  local body
  body=$(cat)
  if [[ "$*" == *"docker login"* ]]; then
    return 0
  fi
  bash -n <<< "$body"
  if [[ "$body" == *" up -d "* ]]; then
    echo rollout >> "$TEST_LOG"
    [[ "${FAIL_ROLLOUT:-false}" != true ]] || return 1
  elif [[ "$body" == *" pull "* ]]; then
    echo pull >> "$TEST_LOG"
  elif [[ "$body" == *"run --rm migrate"* ]]; then
    echo migrate >> "$TEST_LOG"
  elif [[ "$body" == *CURRENT_RELEASE* ]]; then
    echo release >> "$TEST_LOG"
  fi
}
scp() {
  local source=${@: -2:1}
  [[ -f "$source" ]]
  if [[ "$source" == */default.conf ]]; then
    ! grep -q '__[A-Z_]*__' "$source"
    grep -q 'server_name .*loresuelvo.com.ar' "$source"
  fi
}
export -f ssh scp

for app in api webapp; do
  secrets="$test_dir/$app.env"
  if [[ "$app" == api ]]; then
    printf "DATABASE_URL='fixture'\n" > "$secrets"
    expected=$'pull\npull\nmigrate\nrollout\nrollout\nrelease\nrelease'
  else
    printf "AUTH0_CLIENT_ID='fixture'\nAUTH0_CLIENT_SECRET='fixture'\nAUTH0_SECRET='fixture'\n" > "$secrets"
    expected=$'pull\npull\nrollout\nrollout\nrelease\nrelease'
  fi
  image="ghcr.io/loresuelvo/$app@sha256:$(printf '%064d' 0)"
  for environment in staging production; do
    config=staging
    [[ "$environment" != production ]] || config=prod
    : > "$TEST_LOG"
    bash "scripts/deployment/deploy-$app.sh" "$environment" node1,node2 "$image" v1.2.3 "deploy/$app/config/$config.conf" "$secrets"
    [[ "$(cat "$TEST_LOG")" == "$expected" ]]
  done
  if [[ "$app" == api ]]; then
    : > "$TEST_LOG"
    bash scripts/deployment/deploy-api.sh staging node1,node2 "$image" v1.2.3 \
      deploy/api/config/staging.conf "$secrets" hydrate
    ! grep -q '^migrate$' "$TEST_LOG"
    [[ $(grep -c '^rollout$' "$TEST_LOG") == 2 ]]
  fi
  : > "$TEST_LOG"
  if FAIL_ROLLOUT=true bash "scripts/deployment/deploy-$app.sh" staging node1,node2 "$image" v1.2.3 "deploy/$app/config/staging.conf" "$secrets"; then
    exit 1
  fi
  [[ $(grep -c '^rollout$' "$TEST_LOG") == 1 ]]
  ! grep -q '^release$' "$TEST_LOG"
  for hosts in '' node1,node1 '-invalid'; do
    if bash "scripts/deployment/deploy-$app.sh" staging "$hosts" "$image" v1.2.3 "deploy/$app/config/staging.conf" "$secrets"; then
      exit 1
    fi
  done
done
for environment in staging production; do
  bash scripts/deployment/deploy-gateway.sh "$environment" node1,node2 \
    "nginx@sha256:$(printf '%064d' 0)" 1.29.1-alpine
done
echo "Deployment orchestration checks passed."
