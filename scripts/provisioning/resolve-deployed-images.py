#!/usr/bin/env python3
"""Resolve immutable images from the latest successful GitHub Deployments."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

COMPONENTS = {
    "api": ("LoResuelvo/loresuelvo-api", r"^v\d+\.\d+\.\d+$", r"^ghcr\.io/loresuelvo/api@sha256:[a-f0-9]{64}$"),
    "webapp": ("LoResuelvo/loresuelvo-webapp", r"^v\d+\.\d+\.\d+$", r"^ghcr\.io/loresuelvo/webapp@sha256:[a-f0-9]{64}$"),
    "gateway": ("LoResuelvo/infra-devops", r"^\d+\.\d+\.\d+(?:-alpine)?$", r"^nginx@sha256:[a-f0-9]{64}$"),
}


def request_json(url: str) -> Any:
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "loresuelvo-replica-provisioning",
    }
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as response:
        return json.load(response)


def latest_successful(component: str, environment: str, api_url: str) -> tuple[str, str]:
    repository, tag_pattern, image_pattern = COMPONENTS[component]
    query = urllib.parse.urlencode({"environment": environment, "per_page": 20})
    deployments = request_json(f"{api_url}/repos/{repository}/deployments?{query}")
    for deployment in deployments:
        statuses = request_json(f'{api_url}/repos/{repository}/deployments/{deployment["id"]}/statuses?per_page=1')
        if not statuses or statuses[0].get("state") != "success":
            continue
        environment_url = statuses[0].get("environment_url") or ""
        parsed = urllib.parse.urlparse(environment_url)
        if parsed.scheme != "https" or parsed.netloc != "github.com":
            continue
        try:
            metadata = urllib.parse.parse_qs(parsed.fragment, strict_parsing=True)
        except ValueError:
            continue
        if set(metadata) != {"release_tag", "image_ref"}:
            continue
        release_tag = metadata["release_tag"][0]
        image_ref = metadata["image_ref"][0]
        if re.fullmatch(tag_pattern, release_tag) and re.fullmatch(image_pattern, image_ref):
            return release_tag, image_ref
    raise SystemExit(f"No valid successful {component} deployment exists for {environment}.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("environment", choices=("staging", "production"))
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    values: dict[str, str] = {}
    for component in COMPONENTS:
        tag, image = latest_successful(component, args.environment, api_url)
        prefix = "WEBAPP" if component == "webapp" else component.upper()
        values[f"{prefix}_RELEASE_TAG"] = tag
        values[f"{prefix}_IMAGE_REF"] = image
    args.output.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
    args.output.chmod(0o600)


if __name__ == "__main__":
    main()
