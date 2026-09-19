import base64
import gzip
import io
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from campaign.analysis import recovery_status, summarize
from campaign import configuration
from campaign.configuration import check_history, load_config
from campaign.docker_runner import IMAGE, load_plan, read_live_points, sustained_failures
from campaign.reports import aggregate
from run import execute, safe_to_increase


@pytest.fixture
def config():
    return {
        "environment": "staging",
        "api_url": "http://127.0.0.1:18089",
        "web_url": "http://127.0.0.1:18089",
        "cookie": "private-cookie-canary",
        "categories": [
            {
                "id": category_id,
                "name": "Synthetic",
                "min_providers": 1,
                "provider_ids": [10],
                "web_markers": ["synthetic-result"],
            }
            for category_id in (1, 2)
        ],
    }


def test_private_config(tmp_path, config):
    path = tmp_path / "config.json"
    path.write_text(json.dumps(config))
    path.chmod(0o600)
    assert load_config(path, local=True) == config

    path.chmod(0o644)
    with pytest.raises(ValueError):
        load_config(path, local=True)


@pytest.mark.parametrize(
    "change",
    [
        {"environment": "production"},
        {"api_url": "https://loresuelvo.com.ar"},
        {"categories": []},
        {"api_url": "http://127.0.0.1/path"},
    ],
)
def test_invalid_config(tmp_path, config, change):
    path = tmp_path / "config.json"
    path.write_text(json.dumps(dict(config, **change)))
    with pytest.raises((ValueError, KeyError)):
        load_config(path, local=True)


@pytest.mark.parametrize(
    "windows, expected",
    [
        ({index: [(100, False)] * 20 for index in range(12)}, "recovered_by_45s"),
        (
            {index: [(100 if index < 6 else 200, False)] * 20 for index in range(12)},
            "not_recovered_within_90s",
        ),
        ({}, "inconclusive"),
    ],
)
def test_recovery(windows, expected):
    assert recovery_status(windows) == expected


def test_requires_prior_smoke(tmp_path, monkeypatch):
    monkeypatch.setattr(configuration, "REPOSITORY_ROOT", tmp_path)
    history = tmp_path / "results"
    history.mkdir()
    with pytest.raises(ValueError):
        check_history(history, "api", 1, "explore", None)
    (history / "summary.json").write_text(
        json.dumps(
            {
                "valid": True,
                "scenario": "api",
                "nodes": 1,
                "profile": "smoke",
            }
        )
    )
    check_history(history, "api", 1, "explore", None)


def test_live_reader_waits_for_complete_line():
    record = json.dumps({"type": "Point", "metric": "operations", "data": {"value": 1}})
    stream = io.StringIO(record + "\n" + record[:10])
    assert len(read_live_points(stream)) == 1
    assert stream.tell() == len(record) + 1


@pytest.mark.parametrize("values, expected", [([1, 1, 1], True), ([1, 0, 1], False), ([], False)])
def test_watchdog(values, expected):
    points = [
        {
            "metric": "operation_failed",
            "data": {"time": f"2026-01-01T00:00:{second:02d}Z", "value": value},
        }
        for second, value in zip((5, 15, 25), values)
    ]
    assert sustained_failures(points, now=1767225630) is expected


def test_summary_contract():
    points = [
        {
            "metric": "operation_ms",
            "data": {"value": 100, "tags": {"window": "0", "failed": "false"}},
        },
        {"metric": "http_reqs", "data": {"value": 2}},
        {"metric": "http_req_failed", "data": {"value": 0}},
    ]
    result = summarize(points, {"scenario": "api", "profile": "smoke", "seconds": 30}, 0)
    assert result["valid"]
    assert (result["p50"], result["p95"], result["p99"]) == (100, 100, 100)
    assert result["completed_ops_s"] == 1 / 30
    assert result["requests_s"] == 2 / 30
    assert result["network_errors"] == 0
    assert not summarize(points, {"scenario": "api", "profile": "smoke", "seconds": 30}, 1)["valid"]


def test_exploration_continues_past_slo_but_not_generator_failure():
    result = {
        "samples": 60,
        "dropped": 0,
        "network_errors": 0,
        "error_rate": 0,
        "http_error_rate": 0,
        "exit_code": 99,
    }
    assert safe_to_increase(result)
    assert not safe_to_increase(dict(result, network_errors=1))
    assert not safe_to_increase(dict(result, dropped=1))
    assert not safe_to_increase(dict(result, error_rate=0.06))


class SearchHandler(BaseHTTPRequestHandler):
    mode = "ok"

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "/login")
            self.end_headers()
            return
        if self.mode == "expired":
            self.send_response(401)
            self.end_headers()
            return

        is_web = "/consumidor/" in self.path
        self.send_response(200)
        self.send_header("Content-Type", "text/html" if is_web else "application/json")
        self.send_header("CF-Cache-Status", "HIT" if self.mode == "cached" else "DYNAMIC")
        self.end_headers()

        if self.mode == "wrong":
            body = "wrong content"
        elif is_web:
            body = "<html>provider-card synthetic-result</html>"
        elif self.path == "/categories":
            body = json.dumps([{"id": 1, "name": "Synthetic"}, {"id": 2, "name": "Synthetic"}])
        else:
            body = json.dumps([{"id": 10, "category_name": "Synthetic"}])
        self.wfile.write(body.encode())


@pytest.fixture
def server(config):
    server = ThreadingHTTPServer(("127.0.0.1", 0), SearchHandler)
    SearchHandler.mode = "ok"
    origin = f"http://127.0.0.1:{server.server_port}"
    config.update(api_url=origin, web_url=origin)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server
    server.shutdown()
    server.server_close()
    thread.join()


def metadata(scenario, profile="smoke", seconds=1, rate=None):
    return dict(
        scenario=scenario,
        profile=profile,
        nodes=1,
        seconds=seconds,
        offered_ops_s=None,
        reference_R=rate,
        repetition=1,
        image=IMAGE,
    )


@pytest.mark.docker
@pytest.mark.parametrize(
    "scenario, mode, valid",
    [
        ("api", "ok", True),
        ("web", "ok", True),
        ("api", "redirect", False),
        ("web", "expired", False),
        ("api", "wrong", False),
        ("api", "cached", False),
    ],
)
def test_http_contract_and_private_exports(report_dir, config, server, scenario, mode, valid):
    SearchHandler.mode = mode
    folder = report_dir / "run"
    executor = dict(executor="shared-iterations", vus=1, iterations=2, maxDuration="10s")
    result = execute(config, folder, metadata(scenario), executor, report_dir / "STOP")
    assert result["valid"] == valid

    for filename in ("summary.json", "report.html", "points.jsonl", "k6-summary.json"):
        content = (folder / filename).read_text()
        assert "private-cookie-canary" not in content
        assert config["api_url"] not in content
    aggregate(report_dir)
    assert "private-cookie-canary" not in (report_dir / "report.md").read_text()


@pytest.mark.docker
@pytest.mark.parametrize(
    "profile, rate, seconds, rates",
    [
        ("smoke", None, 30, [None]),
        ("warmup", None, 60, [1]),
        ("explore", None, 60, [1, 2, 5, 10, 20, 40]),
        ("sustained", 10, 180, [10, 10]),
        ("spike", 5, 180, [5]),
    ],
)
def test_k6_plan(profile, rate, seconds, rates):
    plan = load_plan(profile, rate)
    assert [entry[2] for entry in plan] == rates
    assert all(entry[1] == seconds for entry in plan)


@pytest.mark.parametrize("profile, rate", [
    ("explore", 0), ("explore", -1), ("explore", 100),
    ("sustained", None), ("spike", None), ("smoke", 5),
    ("warmup", 5), ("unknown", None),
])
def test_invalid_plan_rejected_before_docker(profile, rate, monkeypatch):
    def unexpected_process(*args, **kwargs):
        pytest.fail("Invalid configuration must not start Docker")

    monkeypatch.setattr("campaign.docker_runner.subprocess.run", unexpected_process)
    with pytest.raises(ValueError):
        load_plan(profile, rate)


@pytest.mark.docker
def test_spike_executor(report_dir, config, server):
    executor, _, _ = load_plan("spike", 5)[0]
    assert executor["startRate"] == 5
    assert executor["timeUnit"] == "4s"
    assert [stage["target"] for stage in executor["stages"]] == [5, 20, 20, 5, 5]
    for stage in executor["stages"]:
        if stage["duration"] != "0s":
            stage["duration"] = "1s"
    result = execute(
        config,
        report_dir / "spike",
        metadata("api", "spike", 3, 5),
        executor,
        report_dir / "STOP",
    )
    assert result["valid"]
    assert result["recovery"] == "inconclusive"


@pytest.mark.docker
def test_native_dashboard_for_complete_smoke(report_dir, config, server):
    executor, seconds, rate = load_plan("smoke", None)[0]
    folder = report_dir / "smoke"
    result = execute(config, folder, metadata("api", seconds=seconds), executor, report_dir / "STOP")
    assert result["valid"]
    dashboard = (folder / "report.html").read_bytes()
    fallback = (folder / "summary.html").read_bytes()
    assert dashboard != fallback, "Full smoke must export the native dashboard"
    assert b"private-cookie-canary" not in dashboard
    assert config["api_url"].encode() not in dashboard

    # El dashboard comprime sus datos: revisar también el contenido decodificado.
    encoded = re.search(rb'<script id="data"[^>]*>(.*?)</script>', dashboard, re.DOTALL)
    events = gzip.decompress(base64.b64decode(encoded[1]))
    assert b"private-cookie-canary" not in events
    assert config["api_url"].encode() not in events
    assert b"operation_ms" in events
    assert b"operations" in events
    assert b"http_reqs" in events



def test_results_directory_does_not_allow_sessions(monkeypatch, tmp_path):
    repository = tmp_path / "repo"
    monkeypatch.setattr(configuration, "REPOSITORY_ROOT", repository)
    output = repository / "results" / "campaign" / "run-1"
    assert configuration.results_path(output) == output
    with pytest.raises(ValueError):
        configuration.results_path(tmp_path / "external")
    with pytest.raises(ValueError):
        configuration.results_path(repository / "tracked-report")
    with pytest.raises(ValueError):
        configuration.private_path(output / "session.json")
