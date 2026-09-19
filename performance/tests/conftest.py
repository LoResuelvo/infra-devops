import os
import tempfile
from pathlib import Path

import pytest


def pytest_addoption(parser):
    parser.addoption("--docker", action="store_true", help="Run local k6 integration tests")


def pytest_collection_modifyitems(config, items):
    if not config.getoption("--docker"):
        for item in items:
            if "docker" in item.keywords:
                item.add_marker(pytest.mark.skip(reason="requires --docker"))


@pytest.fixture(autouse=True)
def private_permissions():
    previous = os.umask(0o077)
    yield
    os.umask(previous)


@pytest.fixture(scope="session")
def reports_root():
    root = Path(__file__).resolve().parents[2] / "results" / "tests"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="validation-", dir=root))


@pytest.fixture
def report_dir(reports_root, request):
    directory = reports_root / request.node.name
    directory.mkdir(mode=0o700)
    return directory
