import json
from pathlib import Path
import unittest

from jinja2 import Environment, FileSystemLoader, StrictUndefined


GATEWAY = Path(__file__).resolve().parents[2] / "deploy/gateway"


class GatewayAppLinksTests(unittest.TestCase):
    def render(self, environment):
        config = dict(line.split("=", 1) for line in
                      (GATEWAY / "config" / f"{environment}.conf").read_text().splitlines()
                      if line and not line.startswith("#"))
        package = config["ANDROID_APP_LINK_PACKAGE_NAME"]
        additional = json.loads((GATEWAY / "config/additional-android-app-links.json").read_text())
        template = Environment(loader=FileSystemLoader(GATEWAY / "nginx"),
                               undefined=StrictUndefined).get_template("assetlinks.json.template")
        return json.loads(template.render(
            android_app_link_package_name=package,
            android_app_link_sha256_cert_fingerprint=config["ANDROID_APP_LINK_SHA256_CERT_FINGERPRINT"],
            android_app_link_additional_apps=additional.get(package, []),
        ))

    def test_staging_authorizes_both_distributed_apps(self):
        statements = self.render("staging")
        self.assertEqual(len(statements), 2)
        targets = {item["target"]["package_name"]: item["target"] for item in statements}
        self.assertEqual(set(targets), {"com.loresuelvo.consumer.staging",
                                       "com.loresuelvo.serviceprovider.staging"})
        self.assertEqual(targets["com.loresuelvo.consumer.staging"]["sha256_cert_fingerprints"],
                         ["10:F5:32:D3:22:40:BC:6D:E5:72:73:92:27:8E:E3:A7:22:73:47:9F:57:0E:94:45:04:AA:29:E7:09:17:D5:1A"])
        self.assertEqual(targets["com.loresuelvo.serviceprovider.staging"]["sha256_cert_fingerprints"],
                         ["51:36:E5:2E:52:A0:E8:6A:CF:80:95:B8:85:C8:D1:C8:63:2D:CF:BF:D7:D9:56:65:C3:B4:5C:4F:13:20:7B:85"])
        for item in statements:
            self.assertEqual(item["relation"], ["delegate_permission/common.handle_all_urls"])
            self.assertEqual(item["target"]["namespace"], "android_app")

    def test_production_does_not_authorize_staging_certificates(self):
        statements = self.render("prod")
        self.assertEqual(len(statements), 1)
        self.assertEqual(statements[0]["target"]["package_name"], "com.loresuelvo.consumer")
