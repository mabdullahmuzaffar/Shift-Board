import os

import pytest

# Force SQLite before anything imports app.config.
os.environ["SHIFTBOARD_DB_URL_OVERRIDE"] = "sqlite:///:memory:"
os.environ["SHIFTBOARD_SERVICEBUS_ENABLED"] = "false"
os.environ["SHIFTBOARD_AUTH_ENABLED"] = "false"
os.environ["SHIFTBOARD_OTLP_ENDPOINT"] = ""
os.environ["SHIFTBOARD_ENVIRONMENT"] = "local"

from fastapi.testclient import TestClient  # noqa: E402

from app.db import get_engine, reset_engine  # noqa: E402
from app.main import app  # noqa: E402
from app.messaging import NullPublisher, set_publisher  # noqa: E402
from app.models import Base  # noqa: E402


@pytest.fixture
def publisher() -> NullPublisher:
    pub = NullPublisher()
    set_publisher(pub)
    yield pub
    set_publisher(None)


@pytest.fixture
def client(publisher) -> TestClient:
    reset_engine()
    engine = get_engine()
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    with TestClient(app) as c:
        yield c
    Base.metadata.drop_all(engine)


@pytest.fixture
def site(client) -> dict:
    r = client.post("/api/v1/sites", json={"name": "Lahore Central", "timezone": "Asia/Karachi"})
    assert r.status_code == 201, r.text
    return r.json()


@pytest.fixture
def worker(client) -> dict:
    r = client.post(
        "/api/v1/workers",
        json={"external_id": "emp-001", "display_name": "A. Rahman", "max_weekly_hours": 40},
    )
    assert r.status_code == 201, r.text
    return r.json()
