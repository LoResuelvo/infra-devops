#!/usr/bin/env bash
set -euo pipefail

readonly validation_host="test-ansible-validation-01"
readonly script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly repository_root=$(cd "$script_directory/.." && pwd)
readonly terraform_root="$repository_root/terraform/environments/test/replicas"
readonly inventory="$repository_root/ansible/inventories/test/hosts.yml"
readonly deploy_keys="$repository_root/ansible/vars/deploy-keys.yml"
readonly operator_private_key="${LORESUELVO_OPERATOR_PRIVATE_KEY:-${HOME}/.ssh/loresuelvo_terraform}"
readonly ansible_playbook="$repository_root/.venv/bin/ansible-playbook"
readonly idempotence_check="$repository_root/ansible/tests/check-idempotence.sh"

usage() {
  cat <<'EOF'
Usage: scripts/configure-test-ansible-validation.sh

Reads test-ansible-validation-01 from Terraform state, generates the ignored
Ansible inventory, waits for SSH/cloud-init, checks configuration idempotence,
and verifies the node. It never runs terraform plan, apply, or destroy.

Override the operator key path with LORESUELVO_OPERATOR_PRIVATE_KEY.
EOF
}

if [[ ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

for command in terraform python3 ssh; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

for required_file in \
  "$terraform_root/terraform.tfvars" \
  "$deploy_keys" \
  "$operator_private_key" \
  "$ansible_playbook" \
  "$idempotence_check"; do
  if [[ ! -f $required_file ]]; then
    echo "Required file not found: $required_file" >&2
    exit 1
  fi
done

if [[ $(stat -c '%a' "$operator_private_key") != "600" ]]; then
  echo "Operator private key must have mode 600: $operator_private_key" >&2
  exit 1
fi

replica_ip=$(
  terraform -chdir="$terraform_root" output -json replica_ipv4 |
    python3 -c '
import ipaddress
import json
import sys

target = sys.argv[1]
replicas = json.load(sys.stdin)
if set(replicas) != {target}:
    names = ", ".join(sorted(replicas)) or "none"
    raise SystemExit(
        f"expected only {target!r} in replica_ipv4; found: {names}"
    )
address = str(ipaddress.IPv4Address(replicas[target]))
print(address)
' "$validation_host"
)

umask 077
inventory_directory=$(dirname "$inventory")
inventory_temporary=$(mktemp "$inventory_directory/hosts.yml.XXXXXX")
trap 'rm -f "$inventory_temporary"' EXIT

cat >"$inventory_temporary" <<EOF
---
all:
  children:
    application_nodes:
      hosts:
        $validation_host:
          ansible_host: $replica_ip
          ansible_user: ubuntu
          ansible_ssh_private_key_file: $operator_private_key
EOF

mv "$inventory_temporary" "$inventory"
trap - EXIT
echo "Generated ignored inventory for $validation_host ($replica_ip)."

ssh_options=(
  -i "$operator_private_key"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
)

echo "Waiting for SSH..."
for attempt in $(seq 1 60); do
  if ssh "${ssh_options[@]}" "ubuntu@$replica_ip" true >/dev/null 2>&1; then
    break
  fi
  if [[ $attempt -eq 60 ]]; then
    echo "SSH did not become available after 10 minutes." >&2
    exit 1
  fi
  sleep 10
done

echo "Waiting for cloud-init (the VM may reboot once)..."
for attempt in $(seq 1 90); do
  if ssh "${ssh_options[@]}" "ubuntu@$replica_ip" \
    'cloud-init status --wait 2>/dev/null | grep -q "status: done"'; then
    break
  fi
  if [[ $attempt -eq 90 ]]; then
    echo "Cloud-init did not finish successfully after 15 minutes." >&2
    exit 1
  fi
  sleep 10
done

"$idempotence_check" "$inventory" "$validation_host" "$deploy_keys"

"$ansible_playbook" \
  -i "$inventory" \
  -e "@$deploy_keys" \
  --limit "$validation_host" \
  "$repository_root/ansible/playbooks/verify-application-nodes.yml"

echo "$validation_host was configured idempotently and verified."
