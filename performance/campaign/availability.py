"""Analizar continuidad antes, durante y después del retiro de una réplica."""

import argparse
import json
from collections import Counter
from datetime import datetime

from .analysis import metric_values, network_errors, percentile
from .configuration import results_path
from .docker_runner import read_finished_points


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def operations(points):
    rows = []
    for point in points:
        if point["metric"] != "operation_ms":
            continue
        data = point["data"]
        tags = data["tags"]
        rows.append({
            "start": float(tags["started_ms"]) / 1000,
            "end": timestamp(data["time"]),
            "duration_ms": data["value"],
            "failed": tags["failed"] == "true",
            "kind": tags.get("failure_kind", "unknown"),
        })
    return rows


def phase_summary(rows, start, end, rate, p95_limit_ms=1500):
    selected = [row for row in rows if start <= row["start"] < end]
    successes = sorted(row["end"] for row in rows if not row["failed"] and start <= row["end"] < end)
    gaps = [b - a for a, b in zip([start, *successes], [*successes, end])]
    durations = [row["duration_ms"] for row in selected]
    errors = sum(row["failed"] for row in selected)
    expected = (end - start) * rate
    complete = abs(len(selected) - expected) <= 2
    error_rate = errors / len(selected) if selected else None
    p95 = percentile(durations, .95)
    return {
        "seconds": end - start,
        "samples": len(selected),
        "offered_operations": expected,
        "completed_ops_s": len(selected) / (end - start),
        "p50": percentile(durations, .5),
        "p95": p95,
        "p99": percentile(durations, .99),
        "errors": errors,
        "error_rate": error_rate,
        "failure_kinds": dict(Counter(row["kind"] for row in selected if row["failed"])),
        "max_gap_without_success_s": max(gaps),
        "complete": complete,
        "slo_met": bool(complete and selected and p95 < p95_limit_ms and error_rate < .01),
        "continuity_observed": bool(complete and max(gaps) <= 10),
    }


def analyze(points, drain_start, drain_end, rate, exit_code, malformed=False, p95_limit_ms=1500):
    rows = operations(points)
    result = {"rate": rate, "p95_limit_ms": p95_limit_ms, "phases": {},
              "assessment": "inconclusive", "passed": False}
    if not rows:
        return dict(result, reason="no_operations")

    start = min(row["start"] for row in rows)
    end = start + 1200
    if not (start + 295 <= drain_start < drain_end <= end - 300):
        return dict(result, reason="insufficient_phase_duration")

    for name, phase_start, phase_end in (
        ("before", start, drain_start),
        ("transition", drain_start, drain_end),
        ("after", drain_end, end),
    ):
        result["phases"][name] = phase_summary(rows, phase_start, phase_end, rate, p95_limit_ms)

    result["transport_errors"] = network_errors(points)
    result["dropped"] = sum(metric_values(points, "dropped_iterations"))
    valid = (
        not malformed
        and exit_code in (0, 99)
        and not result["transport_errors"]
        and not result["dropped"]
        and all(phase["complete"] for phase in result["phases"].values())
    )
    result["measurement_valid"] = valid
    if not valid:
        return dict(result, reason="incomplete_load_or_transport_failure")

    before = result["phases"]["before"]
    result["passed"] = all(
        phase["slo_met"] and phase["continuity_observed"]
        for phase in result["phases"].values()
    ) and all(
        result["phases"][name]["error_rate"] <= before["error_rate"] + .01
        for name in ("transition", "after")
    )
    result["assessment"] = "passed" if result["passed"] else "criteria_not_met"
    result["reason"] = "descriptive_observation_not_statistical_noninferiority"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", required=True, help="Directorio de la corrida bajo results/")
    parser.add_argument("--drain-start", required=True, help="Inicio ISO-8601 del retiro en el workflow")
    parser.add_argument("--drain-end", required=True, help="Fin ISO-8601 verificado del retiro")
    parser.add_argument("--rate", required=True, type=float, choices=(.5, 1))
    args = parser.parse_args()

    run = results_path(args.run)
    points, malformed = read_finished_points(run / "points.jsonl")
    summary = json.loads((run / "summary.json").read_text())
    result = analyze(
        points,
        timestamp(args.drain_start),
        timestamp(args.drain_end),
        args.rate,
        summary["exit_code"],
        malformed,
        summary.get("p95_limit_ms", 1500),
    )
    (run / "availability.json").write_text(json.dumps(result, indent=2) + "\n")
    print(result["assessment"])


if __name__ == "__main__":
    main()
