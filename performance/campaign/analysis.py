"""Estadísticas por ejecución y recuperación; no ejecuta procesos ni genera HTML."""

import math
import statistics


def percentile(values, fraction):
    """Percentil por rango más próximo, igual al cálculo original de la campaña."""
    if not values:
        return None
    index = max(0, math.ceil(len(values) * fraction) - 1)
    return sorted(values)[index]


def recovery_status(windows):
    # ponytail: 20 muestras/ventana es descriptivo; ampliar ventanas para tasas bajas.
    baseline = [duration for index in range(4) for duration, _ in windows.get(index, [])]
    if len(baseline) < 20:
        return "inconclusive"

    recovery_ceiling = percentile(baseline, 0.95) * 1.2
    consecutive_windows = 0
    insufficient_samples = False

    # Ventanas 0–3: base; 4–5: pico; 6–11: los 90 segundos de recuperación.
    for index in range(6, 12):
        samples = windows.get(index, [])
        if len(samples) < 20:
            insufficient_samples = True
            consecutive_windows = 0
            continue

        durations = [duration for duration, _ in samples]
        error_rate = statistics.mean(failed for _, failed in samples)
        recovered = percentile(durations, 0.95) <= recovery_ceiling and error_rate < 0.01
        consecutive_windows = consecutive_windows + 1 if recovered else 0
        if consecutive_windows == 3:
            seconds_after_peak = (index + 1) * 15 - 90
            return f"recovered_by_{seconds_after_peak}s"

    if insufficient_samples:
        return "inconclusive"
    return "not_recovered_within_90s"


def metric_values(points, metric):
    return [point["data"]["value"] for point in points if point["metric"] == metric]


def network_errors(points):
    return sum(
        point["data"]["value"]
        for point in points
        if point["metric"] == "http_req_failed"
        and point["data"].get("tags", {}).get("status") == "0"
    )


def summarize(points, metadata, exit_code):
    operations = [point["data"] for point in points if point["metric"] == "operation_ms"]
    durations = [operation["value"] for operation in operations]
    windows = {}
    for operation in operations:
        window_index = int(operation["tags"]["window"])
        failed = operation["tags"]["failed"] == "true"
        windows.setdefault(window_index, []).append((operation["value"], failed))

    failures = sum(operation["tags"]["failed"] == "true" for operation in operations)
    error_rate = failures / len(operations) if operations else 1
    dropped = sum(metric_values(points, "dropped_iterations"))
    requests = sum(metric_values(points, "http_reqs"))
    http_errors = metric_values(points, "http_req_failed")
    http_error_rate = statistics.mean(http_errors) if http_errors else 1
    p95 = percentile(durations, 0.95)
    p95_limit = 1500

    valid = (
        bool(durations)
        and exit_code == 0
        and dropped == 0
        and error_rate < 0.01
        and http_error_rate < 0.01
        and p95 < p95_limit
    )
    result = dict(
        metadata,
        samples=len(operations),
        p50=percentile(durations, 0.5),
        p95=p95,
        p99=percentile(durations, 0.99),
        error_rate=error_rate,
        dropped=dropped,
        http_error_rate=http_error_rate,
        network_errors=network_errors(points),
        requests=requests,
        completed_ops_s=len(operations) / metadata["seconds"],
        requests_s=requests / metadata["seconds"],
        exit_code=exit_code,
        valid=valid,
        recovery=recovery_status(windows) if metadata["profile"] == "spike" else "not_applicable",
    )
    result["windows"] = [
        {
            "second": index * 15,
            "samples": len(samples),
            "p95": percentile([duration for duration, _ in samples], 0.95),
            "error_rate": statistics.mean(failed for _, failed in samples),
        }
        for index, samples in sorted(windows.items())
    ]
    return result
