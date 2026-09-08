import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validator = load("validator", "scripts/provisioning/validate-replica-change.py")
releases = load("releases", "scripts/provisioning/resolve-deployed-images.py")


class ProvisioningTests(unittest.TestCase):
    def test_counts_and_state(self):
        validator.validate_count(2, 2)
        validator.validate_count(2, 3)
        validator.validate_state(2, 2, 3, "same", "same", 1)
        validator.validate_state(2, 3, 3, "before", "after", 2)
        with self.assertRaises(SystemExit):
            validator.validate_count(3, 2)
        with self.assertRaises(SystemExit):
            validator.validate_state(2, 3, 3, "before", "after", 1)

    def test_plan_allows_only_expected_creates(self):
        changes = [{"address": f'module.replica["staging-replica-03"].openstack_compute_{kind}_v2.instance', "change": {"actions": ["create"]}} for kind in ("keypair", "instance")]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            path.write_text(json.dumps({"resource_changes": changes}))
            validator.validate_plan(path, "staging", 2, 3)
            path.write_text(json.dumps({"resource_changes": changes + [{"address": "primary", "change": {"actions": ["delete"]}}]}))
            with self.assertRaises(SystemExit):
                validator.validate_plan(path, "staging", 2, 3)

    def test_release_resolution_skips_failed_deployments(self):
        image = "ghcr.io/loresuelvo/api@sha256:" + "a" * 64
        responses = [[{"id": 1}, {"id": 2}], [{"state": "failure"}], [{"state": "success", "environment_url": f"https://github.com/release#release_tag=v1.2.3&image_ref={image}"}]]
        with patch.object(releases, "request_json", side_effect=responses):
            self.assertEqual(releases.latest_successful("api", "staging", "https://api.test"), ("v1.2.3", image))


if __name__ == "__main__":
    unittest.main()
