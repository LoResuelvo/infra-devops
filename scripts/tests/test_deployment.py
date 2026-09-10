import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path


PATH = Path(__file__).parents[1] / "deployment.py"
SPEC = importlib.util.spec_from_file_location("deployment", PATH)
deployment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deployment)


class DeploymentTests(unittest.TestCase):
    def test_inventory_and_exact_new_nodes(self):
        value = {
            "replica_names": {"value": ["staging-replica-01", "staging-replica-02"]},
            "replica_ipv4": {"value": ["192.0.2.2", "192.0.2.3"]},
        }
        with mock.patch.dict("os.environ", {"TF_PRIMARY_INSTANCE_NAME": "staging-primary", "TF_PRIMARY_INSTANCE_IPV4": "192.0.2.1"}):
            parsed = deployment.terraform_hosts(value)
        result = deployment.inventory(deployment.new_hosts(parsed, "staging", 1, 2), "ubuntu")
        hosts = result["all"]["children"]["application_nodes"]["hosts"]
        self.assertEqual(hosts, {"staging-replica-02": {"ansible_host": "192.0.2.3", "ansible_user": "ubuntu"}})

    def test_invalid_or_duplicate_hosts_are_rejected(self):
        with self.assertRaises(SystemExit):
            deployment.hosts([{"role": "replica", "name": "x", "ipv4": "bad"}])
        duplicate = [{"role": "replica", "name": "x", "ipv4": "192.0.2.1"}] * 2
        with self.assertRaises(SystemExit):
            deployment.hosts(duplicate)

    def test_release_validation(self):
        deployment.validate_release("api", "LoResuelvo/loresuelvo-api", "tag", "v1.2.3", "ghcr.io/loresuelvo/api@sha256:" + "a" * 64, "v1.2.3")
        with self.assertRaises(SystemExit):
            deployment.validate_release("api", "other/repo", "tag", "v1.2.3", "x", "v1.2.3")

        with self.assertRaises(SystemExit):
            deployment.new_hosts(deployment.hosts([{"role": "primary", "name": "staging-primary", "ipv4": "192.0.2.1"}]), "staging", 1, 2)

    def test_empty_state_uses_primary_from_infisical(self):
        with mock.patch.dict("os.environ", {"TF_PRIMARY_INSTANCE_NAME": "staging-primary", "TF_PRIMARY_INSTANCE_IPV4": "192.0.2.1"}):
            self.assertEqual(deployment.terraform_hosts({}), [{"role": "primary", "name": "staging-primary", "ipv4": "192.0.2.1"}])

    def test_cloudflare_origins_preserve_manual_endpoints_and_disable_only_high_replicas(self):
        hosts = deployment.hosts([
            {"role": "primary", "name": "staging-primary", "ipv4": "192.0.2.1"},
            {"role": "replica", "name": "staging-replica-01", "ipv4": "192.0.2.2"},
            {"role": "replica", "name": "staging-replica-02", "ipv4": "192.0.2.3"},
        ])
        pool = {"origins": [
            {"name": "staging-primary", "address": "192.0.2.1", "enabled": True, "weight": 1, "healthy": True},
            {"name": "manual-fallback", "address": "192.0.2.10", "enabled": False, "weight": 0.5},
            {"name": "staging-replica-99", "address": "192.0.2.99", "enabled": True},
        ]}
        self.assertEqual(deployment.cloudflare_origins(pool, hosts, "staging", 1, "drain"), {"origins": [
            {"name": "staging-primary", "address": "192.0.2.1", "enabled": True, "weight": 1},
            {"name": "manual-fallback", "address": "192.0.2.10", "enabled": False, "weight": 0.5},
            {"name": "staging-replica-01", "address": "192.0.2.2", "enabled": True, "weight": 1},
            {"name": "staging-replica-02", "address": "192.0.2.3", "enabled": False, "weight": 1},
        ]})

    def test_private_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "inventory.json"
            deployment.write_private(output, {"ok": True})
            self.assertEqual(json.loads(output.read_text()), {"ok": True})
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_hydration_skips_migration(self):
        playbook = Path("ansible/playbooks/deploy-api.yml").read_text()
        migration = playbook.split("- name: Run API migrations", 1)[1].split("- name:", 1)[0]
        self.assertIn("deployment_mode == 'deploy'", migration)


if __name__ == "__main__":
    unittest.main()
