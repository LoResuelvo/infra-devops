"""Ejecución local de k6 y vigilancia global; sin reglas de búsqueda ni reportes."""

import datetime as dt
import json
import os
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

IMAGE = "grafana/k6:1.3.0"
SCRIPTS = Path(__file__).resolve().parents[1] / "k6"


def load_plan(profile, rate):
    """Consultar la matriz JS con el mismo k6 que ejecutará la prueba, sin red."""
    if profile not in ("smoke", "warmup", "explore", "sustained", "spike", "availability"):
        raise ValueError("Unknown profile")
    allowed_rates = (0.5, 1) if profile == "availability" else (1, 2, 5, 10, 20, 40)
    if rate is not None and rate not in allowed_rates:
        raise ValueError("Rate must belong to the bounded exploration matrix")
    if profile in ("sustained", "spike", "availability") and rate is None:
        raise ValueError("A validated reference rate is required")
    if profile in ("smoke", "warmup") and rate is not None:
        raise ValueError("Smoke and warmup use fixed load")
    command = [
        "docker",
        "run",
        "--rm",
        "--network=none",
        f"--volume={SCRIPTS}:/scripts:ro",
        IMAGE,
        "run",
        "--quiet",
        f"--env=PROFILE={profile}",
        f"--env=RATE={rate or ''}",
        "/scripts/profiles.js",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ValueError("k6 did not return a valid execution plan") from None


def read_live_points(stream):
    """Leer solo líneas completas; k6 puede estar escribiendo la última."""
    points = []
    while True:
        position = stream.tell()
        line = stream.readline()
        if not line or not line.endswith("\n"):
            stream.seek(position)
            return points
        record = json.loads(line)
        if record.get("type") == "Point":
            points.append(record)


def sustained_failures(points, now):
    """Tres ventanas contiguas de 10 s con más de 5 % de operaciones fallidas."""
    failures = []
    for point in points:
        if point["metric"] == "operation_failed":
            data = point["data"]
            timestamp = dt.datetime.fromisoformat(data["time"].replace("Z", "+00:00"))
            failures.append((timestamp.timestamp(), data["value"]))

    for index in range(3):
        start = now - (index + 1) * 10
        end = now - index * 10
        values = [failed for timestamp, failed in failures if start <= timestamp < end]
        if not values or statistics.mean(values) <= 0.05:
            return False
    return True


def stop_container(name):
    subprocess.run(["docker", "stop", "--time", "2", name], capture_output=True)


def record_resources(name, stream):
    result = subprocess.run(
        ["docker", "stats", "--no-stream", "--format", "{{json .}}", name],
        capture_output=True,
        text=True,
    )
    stream.write(result.stdout)
    stream.flush()


def monitor(process, name, folder, seconds, stop_file, stats):
    started_at = time.monotonic()
    points = []
    stream = None
    try:
        while process.poll() is None:
            points_path = folder / "points.jsonl"
            if stream is None and points_path.exists():
                stream = points_path.open()
            if stream:
                points.extend(read_live_points(stream))

            elapsed = time.monotonic() - started_at
            now = dt.datetime.now(dt.timezone.utc).timestamp()
            must_stop = (
                stop_file.exists() or sustained_failures(points, now) or elapsed > seconds + 60
            )
            if must_stop:
                stop_container(name)
                return 1

            if int(elapsed) % 5 == 0:
                record_resources(name, stats)
            time.sleep(1)
        return process.wait(timeout=15)
    except KeyboardInterrupt:
        return 1
    finally:
        if stream:
            stream.close()
        if process.poll() is None:
            stop_container(name)
            process.wait(timeout=15)


def run_k6(config, folder, metadata, executor, stop_file):
    folder.mkdir(mode=0o700)
    name = f"loresuelvo-k6-{os.getpid()}"
    with tempfile.TemporaryDirectory(prefix="loresuelvo-k6-") as temporary:
        private_dir = Path(temporary)
        (private_dir / "config.json").write_text(json.dumps(config))
        (private_dir / "plan.json").write_text(json.dumps(dict(metadata, executor=executor)))

        command = [
            "docker",
            "run",
            "--rm",
            f"--name={name}",
            "--network=host",
            "--cpus=2",
            "--memory=2g",
            f"--user={os.getuid()}:{os.getgid()}",
            f"--volume={private_dir}:/private:ro",
            f"--volume={SCRIPTS}:/scripts:ro",
            f"--volume={folder}:/out",
            # Dashboard nativo, solo export: no abre un puerto ni un navegador.
            "--env=K6_WEB_DASHBOARD=true",
            "--env=K6_WEB_DASHBOARD_PORT=-1",
            "--env=K6_WEB_DASHBOARD_PERIOD=5s",
            "--env=K6_WEB_DASHBOARD_EXPORT=/out/report.html",
            "--env=XK6_DASHBOARD_CONFIG=/scripts/dashboard.json",
            IMAGE,
            "run",
            "--quiet",
            "--out",
            "json=/out/points.jsonl",
            "/scripts/search.js",
        ]
        with (folder / "private.log").open("w") as log:
            with (folder / "generator.jsonl").open("w") as stats:
                process = subprocess.Popen(command, stdout=log, stderr=log)
                return monitor(process, name, folder, metadata["seconds"], stop_file, stats)


def read_finished_points(path):
    """Una exportación truncada conserva los puntos legibles pero invalida la corrida."""
    points = []
    malformed = False
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                record = json.loads(line)
                if record.get("type") == "Point":
                    points.append(record)
            except json.JSONDecodeError:
                malformed = True
    return points, malformed
