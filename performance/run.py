#!/usr/bin/env python3
"""LoResuelvo: coordinar una campaña local de lecturas con k6 en Docker."""

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess

from campaign.analysis import summarize
from campaign.configuration import REPOSITORY_ROOT, check_history, check_preflight, load_config, results_path
from campaign.docker_runner import IMAGE, SCRIPTS, load_plan, read_finished_points, run_k6
from campaign.reports import aggregate


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", required=True, help="New output directory under results/")
    parser.add_argument("--scenario", choices=["api", "web"], required=True)
    parser.add_argument("--nodes", type=int, choices=[1, 2], required=True)
    parser.add_argument(
        "--profile",
        choices=["smoke", "warmup", "explore", "sustained", "spike"],
        required=True,
    )
    parser.add_argument("--rate", type=int)
    parser.add_argument("--history", help="Campaign directory under results/ containing prior remote summaries")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def run_metadata(args, config, repetition, seconds, rate):
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPOSITORY_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    dataset_selection = json.dumps(config["categories"], sort_keys=True).encode()
    metadata = {
        "scenario": args.scenario,
        "profile": args.profile,
        "nodes": args.nodes,
        "seconds": seconds,
        "offered_ops_s": rate if args.profile != "spike" else None,
        "reference_R": rate,
        "repetition": repetition,
        "image": IMAGE,
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "source_revision": revision,
        "scenario_sha256": hashlib.sha256((SCRIPTS / "search.js").read_bytes()).hexdigest(),
        "profiles_sha256": hashlib.sha256((SCRIPTS / "profiles.js").read_bytes()).hexdigest(),
        "dataset_selection_sha256": hashlib.sha256(dataset_selection).hexdigest(),
        "offered_operations": None,
    }
    if rate is not None:
        # Pico: (60 + 90) s a R/4 más 30 s a R = 67.5 * R operaciones.
        metadata["offered_operations"] = rate * (67.5 if args.profile == "spike" else seconds)
    if args.profile == "spike":
        metadata["base_ops_s"] = rate / 4
        metadata["peak_ops_s"] = rate
    return metadata


def execute(config, folder, metadata, executor, stop_file):
    folder = results_path(folder)
    exit_code = run_k6(config, folder, metadata, executor, stop_file)
    # k6 omite el dashboard en abortos tempranos; conservar el HTML del resumen.
    dashboard = folder / "report.html"
    fallback = folder / "summary.html"
    if not dashboard.exists() and fallback.exists():
        dashboard.write_bytes(fallback.read_bytes())
    points, malformed = read_finished_points(folder / "points.jsonl")
    if malformed:
        exit_code = 1
    result = summarize(points, metadata, exit_code)
    (folder / "summary.json").write_text(json.dumps(result, indent=2))
    return result


def safe_to_increase(result):
    """El SLO elige R; solo fallos operativos detienen la exploración."""
    return (
        result["samples"] > 0
        and result["dropped"] == 0
        and result["network_errors"] == 0
        and result["error_rate"] <= 0.05
        and result["http_error_rate"] <= 0.05
        and result["exit_code"] in (0, 99)
    )


def main():
    args = parse_args()
    os.umask(0o077)
    config = load_config(args.config)
    if args.scenario == "web" and not config.get("cookie"):
        raise ValueError("Private consumer cookie required")

    runs = load_plan(args.profile, args.rate)
    output = results_path(args.out)
    if args.dry_run:
        print(json.dumps(runs, indent=2))
        return

    if args.profile != "smoke" and not args.history:
        raise ValueError("--history is required after smoke")
    check_history(args.history, args.scenario, args.nodes, args.profile, args.rate)
    check_preflight(config, args.nodes)

    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for repetition, (executor, seconds, rate) in enumerate(runs, start=1):
        metadata = run_metadata(args, config, repetition, seconds, rate)
        folder = output / f"run-{repetition}"
        result = execute(config, folder, metadata, executor, output / "STOP")
        print(f"run-{repetition}: valid={result['valid']}")
        if not result["valid"] and (args.profile != "explore" or not safe_to_increase(result)):
            break
    aggregate(output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        # No incluir valores de configuración ni salida de procesos con secretos.
        raise SystemExit(
            f"Invalid configuration or execution prerequisite: {type(error).__name__}"
        ) from None
