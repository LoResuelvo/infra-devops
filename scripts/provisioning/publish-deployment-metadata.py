#!/usr/bin/env python3
"""Publish release metadata on the completed GitHub deployment."""

import json
import os
import urllib.parse
import urllib.request


def request(method: str, url: str, token: str, payload: object | None = None) -> object:
    data = None if payload is None else json.dumps(payload).encode()
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers, method=method), timeout=20) as response:
        return json.load(response)


def main() -> None:
    token = os.environ["GITHUB_TOKEN"]
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    repository = os.environ["GITHUB_REPOSITORY"]
    environment = os.environ["DEPLOYMENT_ENVIRONMENT"]
    environment_url = os.environ["DEPLOYMENT_URL"]
    query = urllib.parse.urlencode({"environment": environment, "sha": os.environ["GITHUB_SHA"], "per_page": 20})
    deployments = request("GET", f"{api_url}/repos/{repository}/deployments?{query}", token)
    deployment = next((item for item in deployments if item.get("task") == "deploy"), None)
    if deployment is None:
        raise SystemExit(f"Completed {environment} deployment was not found.")
    request(
        "POST",
        f"{api_url}/repos/{repository}/deployments/{deployment['id']}/statuses",
        token,
        {"state": "success", "environment_url": environment_url, "description": "Release metadata published.", "auto_inactive": False},
    )


if __name__ == "__main__":
    main()
