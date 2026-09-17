#!/usr/bin/env python3
"""Validate the gateway image for both environments with disposable TLS files."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from jinja2 import Environment, FileSystemLoader, StrictUndefined


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("image", help="Gateway image to validate")
args = parser.parse_args()
gateway = Path(__file__).resolve().parents[2] / "deploy/gateway"
templates = Environment(loader=FileSystemLoader(gateway / "nginx"), undefined=StrictUndefined)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    tls = root / "tls"
    tls.mkdir()
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(tls / "origin.key"), "-out", str(tls / "origin.crt"),
         "-days", "1", "-subj", "/CN=gateway.test"],
        check=True, capture_output=True,
    )
    for name in ("staging", "prod"):
        config = subprocess.run(
            ["bash", "--noprofile", "--norc", "-euc",
             'source "$1"; printf "%s\\n" "$API_SERVER_NAMES" "$WEB_SERVER_NAMES" '
             '"$ADMIN_SERVER_NAMES" "$ANDROID_APP_LINK_PACKAGE_NAME" '
             '"$ANDROID_APP_LINK_SHA256_CERT_FINGERPRINT"',
             "gateway-config", str(gateway / "config" / f"{name}.conf")],
            check=True, capture_output=True, text=True,
        )
        values = dict(zip(
            ("api_server_names", "web_server_names", "admin_server_names",
             "android_app_link_package_name", "android_app_link_sha256_cert_fingerprint"),
            config.stdout.splitlines(), strict=True,
        ))
        rendered = root / name
        rendered.mkdir()
        for filename in ("default.conf", "assetlinks.json"):
            content = templates.get_template(f"{filename}.template").render(values)
            if filename.endswith(".json"):
                json.loads(content)
            (rendered / filename).write_text(content, encoding="utf-8")
        print(f"Validating gateway configuration: {name}", flush=True)
        subprocess.run(
            ["docker", "run", "--rm", "--network", "none", "--entrypoint", "nginx",
             "--volume", f"{rendered}:/etc/nginx/conf.d:ro",
             "--volume", f"{tls}:/etc/loresuelvo/gateway/tls:ro",
             args.image, "-t"],
            check=True,
        )
