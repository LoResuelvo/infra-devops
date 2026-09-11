#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 INVENTORY LIMIT DEPLOY_KEYS_VARS ENVIRONMENT" >&2
  exit 2
fi

inventory=$1
limit=$2
deploy_keys_vars=$3
environment_name=$4
ansible_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repository_root=$(cd "$ansible_root/.." && pwd)
playbook="$ansible_root/playbooks/configure-application-nodes.yml"
output=$(mktemp)
trap 'rm -f "$output"' EXIT

export ANSIBLE_CONFIG="$repository_root/ansible.cfg"

"$repository_root/.venv/bin/ansible-playbook" \
  -i "$inventory" \
  -e "@$deploy_keys_vars" \
  -e "environment_name=$environment_name" \
  --limit "$limit" \
  "$playbook"

"$repository_root/.venv/bin/ansible-playbook" \
  -i "$inventory" \
  -e "@$deploy_keys_vars" \
  -e "environment_name=$environment_name" \
  --limit "$limit" \
  "$playbook" | tee "$output"

if ! grep -Eq 'changed=0[[:space:]]+unreachable=0[[:space:]]+failed=0' "$output"; then
  echo "The second configuration run was not idempotent." >&2
  exit 1
fi
