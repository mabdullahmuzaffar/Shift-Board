def test_liveness_does_not_touch_database(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["checks"] == {}


def test_readiness_reports_database_check(client):
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json()["checks"]["database"] == "ok"


def test_metrics_endpoint_exposed(client):
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "shiftboard_shifts_created_total" in r.text or "http_requests_total" in r.text


def test_root_returns_service_identity(client):
    r = client.get("/")
    assert r.status_code == 200
    assert r.json()["service"] == "shift-api"
