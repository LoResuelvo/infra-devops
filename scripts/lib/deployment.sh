#!/usr/bin/env bash
# Common deployment input and SSH session helpers.
fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_env() {
  local name=$1
  [[ -n "${!name-}" ]] || fail "Required variable $name is missing."
}

# These helpers populate hosts, work_dir, ssh_key and ssh_options for the caller.
validate_environment() {
  [[ "$1" == staging || "$1" == production ]] || fail "Environment must be staging or production."
}

parse_hosts() {
  local normalized_hosts=${1//,/ }
  normalized_hosts=${normalized_hosts//$'\n'/ }
  local host
  local -A seen_hosts=()
  read -r -a hosts <<< "$normalized_hosts"
  [[ ${#hosts[@]} -gt 0 ]] || fail "At least one deployment host is required."
  for host in "${hosts[@]}"; do
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || fail "Deployment host is invalid."
    [[ -z "${seen_hosts[$host]-}" ]] || fail "Deployment hosts must be unique."
    seen_hosts[$host]=1
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
      printf '::add-mask::%s\n' "$host"
    fi
  done
}

prepare_ssh() {
  require_env DEPLOY_SSH_PRIVATE_KEY
  umask 077
  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"' EXIT
  ssh_key="$work_dir/deploy_key"
  printf '%s\n' "$DEPLOY_SSH_PRIVATE_KEY" > "$ssh_key"
  ssh_options=(
    -i "$ssh_key"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=15
  )
}
