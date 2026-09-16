#!/usr/bin/env python3
"""Validate the gateway image for both environments with disposable TLS files."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("image", help="Gateway image to validate")
args = parser.parse_args()
gateway = Path(__file__).resolve().parents[2] / "deploy/gateway"

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
             '"$ADMIN_SERVER_NAMES" "$ANDROID_APP_LINK_PACKAGE_NAME"',
             "gateway-config", str(gateway / "config" / f"{name}.conf")],
            check=True, capture_output=True, text=True,
        )
        values = dict(zip(
            ("API_SERVER_NAMES", "WEB_SERVER_NAMES", "ADMIN_SERVER_NAMES", "ANDROID_APP_LINK_PACKAGE_NAME"),
            config.stdout.splitlines(), strict=True,
        ))
        values["ANDROID_APP_LINK_SHA256_CERT_FINGERPRINT"] = ":".join(["AA"] * 32)
        print(f"Validating gateway configuration: {name}", flush=True)
        command = [
            "docker", "run", "--rm", "--network", "none",
            "--volume", f"{tls}:/etc/loresuelvo/gateway/tls:ro",
            *(item for key, value in values.items() for item in ("--env", f"{key}={value}")),
            args.image,
        ]
        subprocess.run(
            [*command, "nginx", "-t"],
            check=True,
        )
        assetlinks = subprocess.run(
            [*command, "cat", "/etc/nginx/conf.d/assetlinks.json"],
            check=True, capture_output=True, text=True,
        )
        json.loads(assetlinks.stdout)
