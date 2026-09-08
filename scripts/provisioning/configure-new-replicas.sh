#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 ENVIRONMENT NEW_NODES_JSON" >&2
  exit 2
fi

environment=$1
nodes_json=$2
[[ "$environment" == staging || "$environment" == production ]] || {
  echo "Environment must be staging or production." >&2
  exit 2
}

for command in python3 ssh ansible-playbook; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 1; }
done
: "${OPERATOR_SSH_PRIVATE_KEY:?OPERATOR_SSH_PRIVATE_KEY is required}"
: "${DEPLOY_SSH_PUBLIC_KEYS_JSON:?DEPLOY_SSH_PUBLIC_KEYS_JSON is required}"

script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_directory/../.." && pwd)
runner_temp=${RUNNER_TEMP:-/tmp}
work_dir=$(mktemp -d "$runner_temp/loresuelvo-ansible.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
inventory="$work_dir/hosts.yml"
operator_key="$work_dir/operator_key"
deploy_keys="$work_dir/deploy-keys.yml"
known_hosts="$work_dir/known_hosts"

umask 077
printf '%s\n' "$OPERATOR_SSH_PRIVATE_KEY" > "$operator_key"
NODES_JSON=$nodes_json ENVIRONMENT=$environment INVENTORY=$inventory \
  DEPLOY_KEYS=$deploy_keys DEPLOY_KEYS_JSON=$DEPLOY_SSH_PUBLIC_KEYS_JSON \
  python3 <<'PY'
import ipaddress
import json
import os
import re

environment = os.environ["ENVIRONMENT"]
nodes = json.loads(os.environ["NODES_JSON"])
keys = json.loads(os.environ["DEPLOY_KEYS_JSON"])
if not isinstance(nodes, list) or not nodes:
    raise SystemExit("NEW_NODES_JSON must contain at least one node")
if not isinstance(keys, list) or not keys or not all(isinstance(key, str) for key in keys):
    raise SystemExit("DEPLOY_SSH_PUBLIC_KEYS_JSON must be a non-empty string list")

seen = set()
lines = ["---", "all:", "  children:", "    application_nodes:", "      hosts:"]
for node in nodes:
    if not isinstance(node, dict) or set(node) != {"name", "ipv4"}:
        raise SystemExit("Every new node must contain only name and ipv4")
    name = node["name"]
    expected = rf"{environment}-replica-[0-9]{{2}}"
    if not isinstance(name, str) or not re.fullmatch(expected, name) or name in seen:
        raise SystemExit("A new node has an invalid or duplicate name")
    seen.add(name)
    address = str(ipaddress.IPv4Address(node["ipv4"]))
    lines.extend([
        f"        {name}:",
        f"          ansible_host: {address}",
        "          ansible_user: ubuntu",
    ])
with open(os.environ["INVENTORY"], "w", encoding="utf-8") as stream:
    stream.write("\n".join(lines) + "\n")
with open(os.environ["DEPLOY_KEYS"], "w", encoding="utf-8") as stream:
    json.dump({"deploy_ssh_public_keys": keys}, stream)
    stream.write("\n")
PY

mapfile -t hosts < <(NODES_JSON="$nodes_json" python3 -c '
import json, os
for node in json.loads(os.environ["NODES_JSON"]):
    print(node["ipv4"])
')

ssh_options=(
  -i "$operator_key"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$known_hosts"
  -o ConnectTimeout=10
)
for host in "${hosts[@]}"; do
  [[ "${GITHUB_ACTIONS:-}" != true ]] || printf '::add-mask::%s\n' "$host"
  ready=false
  for attempt in $(seq 1 60); do
    if ssh "${ssh_options[@]}" "ubuntu@$host" true >/dev/null 2>&1; then ready=true; break; fi
    sleep 10
  done
  [[ "$ready" == true ]] || { echo "SSH did not become available for a new node." >&2; exit 1; }

  ready=false
  for attempt in $(seq 1 90); do
    if ssh "${ssh_options[@]}" "ubuntu@$host" \
      'cloud-init status --wait 2>/dev/null | grep -q "status: done"' >/dev/null 2>&1; then ready=true; break; fi
    sleep 10
  done
  [[ "$ready" == true ]] || { echo "Cloud-init did not finish for a new node." >&2; exit 1; }
done

export ANSIBLE_HOST_KEY_CHECKING=True
export ANSIBLE_SSH_ARGS="-o UserKnownHostsFile=$known_hosts -o StrictHostKeyChecking=accept-new"
ansible-playbook -i "$inventory" --private-key "$operator_key" -e "@$deploy_keys" \
  "$repository_root/ansible/playbooks/configure-application-nodes.yml"
ansible-playbook -i "$inventory" --private-key "$operator_key" -e "@$deploy_keys" \
  "$repository_root/ansible/playbooks/verify-application-nodes.yml"

echo "New $environment replicas were configured and verified."
