"""Validación de destinos privados y evidencia previa de la campaña."""

import json
from pathlib import Path
from urllib.parse import urlsplit

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
STAGING_HOSTS = {
    "api_url": "api-test.loresuelvo.com.ar",
    "web_url": "test.loresuelvo.com.ar",
}


def private_path(path):
    resolved = Path(path).expanduser().resolve()
    if resolved == REPOSITORY_ROOT or REPOSITORY_ROOT in resolved.parents:
        raise ValueError("Private configuration must be outside the repository")
    return resolved


def results_path(path):
    """Guardar resultados únicamente en results/, ignorado por Git."""
    resolved = Path(path).expanduser().resolve()
    results_dir = REPOSITORY_ROOT / "results"
    if resolved == results_dir or results_dir in resolved.parents:
        return resolved
    raise ValueError("Reports must be under the repository results/ directory")


def validate_origin(url, expected_host, local):
    origin = urlsplit(url)
    allowed_hosts = ("localhost", "127.0.0.1") if local else (expected_host,)
    has_extra_components = (
        origin.username
        or origin.password
        or origin.query
        or origin.fragment
        or origin.path not in ("", "/")
    )
    if origin.hostname not in allowed_hosts or has_extra_components:
        raise ValueError("Target is not an allowed staging origin")
    if origin.scheme != ("http" if local else "https"):
        raise ValueError("Invalid target scheme")


def validate_category(category):
    valid_category = (
        type(category["id"]) is int
        and category["id"] > 0
        and isinstance(category["name"], str)
        and bool(category["name"])
        and type(category["min_providers"]) is int
        and category["min_providers"] > 0
    )
    if not valid_category:
        raise ValueError("Invalid category")

    provider_ids = category["provider_ids"]
    if not provider_ids or not all(type(value) is int and value > 0 for value in provider_ids):
        raise ValueError("Expected synthetic provider IDs required")

    markers = category["web_markers"]
    if not markers or not all(isinstance(value, str) and value.strip() for value in markers):
        raise ValueError("Expected HTML markers required")


def load_config(path, local=False):
    path = private_path(path)
    if path.stat().st_mode & 0o077:
        raise ValueError("Configuration must have mode 600")

    config = json.loads(path.read_text())
    if config.get("environment") != "staging":
        raise ValueError("environment must be staging")

    for key, host in STAGING_HOSTS.items():
        validate_origin(config[key], host, local)
        config[key] = config[key].rstrip("/")

    categories = config["categories"]
    distinct_ids = {category["id"] for category in categories}
    if len(categories) < 2 or len(distinct_ids) != len(categories):
        raise ValueError("Use at least two distinct populated categories")
    for category in categories:
        validate_category(category)

    cookie = config.get("cookie", "")
    if not isinstance(cookie, str) or "\r" in cookie or "\n" in cookie:
        raise ValueError("Invalid Cookie header")
    return config


def check_history(history, scenario, nodes, profile, rate):
    """No aumentar carga sin smoke y referencia válidos de la misma campaña."""
    if profile == "smoke":
        return

    summaries = [
        json.loads(path.read_text()) for path in results_path(history).glob("**/summary.json")
    ]
    valid_runs = [
        result for result in summaries if result.get("valid") and result.get("scenario") == scenario
    ]
    has_smoke = any(
        result["profile"] == "smoke" and result["nodes"] == nodes for result in valid_runs
    )
    if not has_smoke:
        raise ValueError("A valid remote smoke for this scenario/topology is required")

    if profile not in ("sustained", "spike"):
        return

    has_exploration = any(
        result["profile"] == "explore" and result["nodes"] == 1 and result["reference_R"] == rate
        for result in valid_runs
    )
    if not has_exploration:
        raise ValueError("R must pass one-node exploration first")

    if nodes == 2 or profile == "spike":
        baseline_runs = [
            result
            for result in valid_runs
            if result["profile"] == "sustained"
            and result["nodes"] == 1
            and result["reference_R"] == rate
        ]
        if len(baseline_runs) < 2:
            raise ValueError("Two valid one-node sustained repetitions are required")


def check_preflight(config, nodes):
    required = [
        "isolation",
        "dataset",
        "resources",
        "digests",
        "cloudflare",
        "origin",
        "health",
        "metrics",
    ]
    if nodes == 2:
        required.append("both_nodes_logs")
    if not all(config.get("preflight", {}).get(key) is True for key in required):
        raise ValueError("Complete the private preflight checklist before remote smoke")
