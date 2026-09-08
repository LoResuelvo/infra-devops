#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

terraform() {
  [[ "$*" == *"output -json deployment_hosts"* ]]
  printf '%s\n' '[{"role":"primary","name":"primary","ipv4":"192.0.2.10"},{"role":"replica","name":"staging-replica-01","ipv4":"198.51.100.11"}]'
}
export -f terraform
scripts/deployment/terraform-hosts.sh terraform/environments/staging/replicas "$test_dir/hosts"
[[ "$(cat "$test_dir/hosts")" == $'192.0.2.10\n198.51.100.11' ]]
[[ "$(stat -c '%a' "$test_dir/hosts")" == 600 ]]

ssh() { return 0; }
ansible-playbook() {
  printf 'ansible\n' >> "$TEST_LOG"
  [[ "${FAIL_ANSIBLE:-false}" != true ]]
}
export -f ssh ansible-playbook
export OPERATOR_SSH_PRIVATE_KEY=fixture
export DEPLOY_SSH_PUBLIC_KEYS_JSON='["ssh-ed25519 AAAAfixture"]'
export RUNNER_TEMP=$test_dir
export TEST_LOG=$test_dir/ansible-events
nodes='[{"name":"staging-replica-01","ipv4":"198.51.100.11"}]'

scripts/provisioning/configure-new-replicas.sh staging "$nodes"
[[ $(grep -c '^ansible$' "$TEST_LOG") == 2 ]]

: > "$TEST_LOG"
if FAIL_ANSIBLE=true scripts/provisioning/configure-new-replicas.sh staging "$nodes"; then
  echo "Ansible failure was not propagated." >&2
  exit 1
fi
[[ $(grep -c '^ansible$' "$TEST_LOG") == 1 ]]

echo "Replica provisioning helper checks passed."

validator=scripts/provisioning/validate-replica-change.py
python3 "$validator" context staging terraform/environments/staging/replicas
if python3 "$validator" context staging terraform/environments/production/replicas; then
  echo "Mismatched Terraform root was not rejected." >&2
  exit 1
fi
[[ "$(python3 "$validator" count 2 2)" == unchanged ]]
[[ "$(python3 "$validator" count 2 3)" == grow ]]
[[ "$(python3 "$validator" state 2 2 3 before before 1)" == apply ]]
[[ "$(python3 "$validator" state 2 3 3 before after 2)" == resume ]]
if python3 "$validator" state 2 3 3 before after 1; then
  echo "State changed after approval was not rejected." >&2
  exit 1
fi
if python3 "$validator" count 3 2; then
  echo "Replica reduction was not rejected." >&2
  exit 1
fi

plan_file=$test_dir/plan.json
printf '%s\n' '{"resource_changes":[{"address":"module.replica[\"staging-replica-03\"].openstack_compute_keypair_v2.instance","change":{"actions":["create"]}},{"address":"module.replica[\"staging-replica-03\"].openstack_compute_instance_v2.instance","change":{"actions":["create"]}}]}' > "$plan_file"
python3 "$validator" plan "$plan_file" staging 2 3 >/dev/null
printf '%s\n' '{"resource_changes":[{"address":"module.replica[\"staging-replica-01\"].openstack_compute_instance_v2.instance","change":{"actions":["delete"]}}]}' > "$plan_file"
if python3 "$validator" plan "$plan_file" staging 2 3; then
  echo "Unexpected Terraform changes were not rejected." >&2
  exit 1
fi

echo "Replica count and Terraform plan checks passed."

python3 <<'PY'
import importlib.util
from pathlib import Path

path = Path("scripts/provisioning/resolve-deployed-images.py")
spec = importlib.util.spec_from_file_location("resolve_deployed_images", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

images = {
    "api": ("v1.2.3", "ghcr.io/loresuelvo/api@sha256:" + "a" * 64),
    "webapp": ("v2.3.4", "ghcr.io/loresuelvo/webapp@sha256:" + "b" * 64),
    "gateway": ("1.29.1-alpine", "nginx@sha256:" + "c" * 64),
}

def fake_request(url):
    if "/statuses?" not in url:
        return [{"id": 42}]
    component = next(name for name, (repo, _, _) in module.COMPONENTS.items() if repo in url)
    tag, image = images[component]
    return [{
        "state": "success",
        "environment_url": f"https://github.com/release#release_tag={tag}&image_ref={image}",
    }]

module.request_json = fake_request
for component, expected in images.items():
    assert module.latest_successful(component, "staging", "https://api.github.test") == expected
PY

echo "GitHub Deployment release resolution checks passed."
