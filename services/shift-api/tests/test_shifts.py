from datetime import UTC, datetime, timedelta


def _window(offset_hours: int = 24, length_hours: int = 8) -> tuple[str, str]:
    start = datetime.now(UTC) + timedelta(hours=offset_hours)
    return start.isoformat(), (start + timedelta(hours=length_hours)).isoformat()


def test_create_shift_emits_domain_event(client, site, publisher):
    starts, ends = _window()
    r = client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": starts, "ends_at": ends},
    )
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["status"] == "open"
    assert body["version"] == 1
    assert [e["event_type"] for e in publisher.sent] == ["shift.created"]
    assert publisher.sent[0]["data"]["shift_id"] == body["id"]


def test_create_shift_rejects_unknown_site(client):
    starts, ends = _window()
    r = client.post(
        "/api/v1/shifts",
        json={"site_id": "does-not-exist", "role": "Nurse", "starts_at": starts, "ends_at": ends},
    )
    assert r.status_code == 404


def test_create_shift_rejects_naive_timestamps(client, site):
    r = client.post(
        "/api/v1/shifts",
        json={
            "site_id": site["id"],
            "role": "Nurse",
            "starts_at": "2026-10-01T09:00:00",
            "ends_at": "2026-10-01T17:00:00",
        },
    )
    assert r.status_code == 422


def test_create_shift_rejects_inverted_window(client, site):
    starts, ends = _window()
    r = client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": ends, "ends_at": starts},
    )
    assert r.status_code == 422


def test_create_shift_rejects_overlong_window(client, site):
    starts, _ = _window()
    long_end = (
        datetime.fromisoformat(starts) + timedelta(hours=20)
    ).isoformat()
    r = client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": starts, "ends_at": long_end},
    )
    assert r.status_code == 422


def test_claim_happy_path(client, site, worker, publisher):
    starts, ends = _window()
    shift = client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": starts, "ends_at": ends},
    ).json()

    r = client.post(
        f"/api/v1/shifts/{shift['id']}/claim",
        json={"worker_id": worker["id"], "expected_version": 1},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "claimed"
    assert body["assigned_worker_id"] == worker["id"]
    assert body["version"] == 2
    assert "shift.claimed" in [e["event_type"] for e in publisher.sent]


def test_claim_is_optimistically_locked(client, site, worker):
    """Two workers racing for the same shift: the stale version loses with 409."""
    starts, ends = _window()
    shift = client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": starts, "ends_at": ends},
    ).json()

    first = client.post(
        f"/api/v1/shifts/{shift['id']}/claim",
        json={"worker_id": worker["id"], "expected_version": 1},
    )
    assert first.status_code == 200

    second = client.post(
        f"/api/v1/shifts/{shift['id']}/claim",
        json={"worker_id": worker["id"], "expected_version": 1},
    )
    assert second.status_code == 409
    assert "modified" in second.json()["detail"]


def test_claim_unknown_shift_is_404(client, worker):
    r = client.post(
        "/api/v1/shifts/nope/claim",
        json={"worker_id": worker["id"], "expected_version": 1},
    )
    assert r.status_code == 404


def test_cancel_is_idempotent(client, site):
    starts, ends = _window()
    shift = client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": starts, "ends_at": ends},
    ).json()

    first = client.delete(f"/api/v1/shifts/{shift['id']}")
    assert first.status_code == 200
    assert first.json()["status"] == "cancelled"

    second = client.delete(f"/api/v1/shifts/{shift['id']}")
    assert second.status_code == 200
    assert second.json()["status"] == "cancelled"


def test_list_shifts_filters_and_paginates(client, site):
    for i in range(5):
        starts, ends = _window(offset_hours=24 + i * 24)
        client.post(
            "/api/v1/shifts",
            json={"site_id": site["id"], "role": f"Role-{i}", "starts_at": starts, "ends_at": ends},
        )

    r = client.get("/api/v1/shifts", params={"site_id": site["id"], "limit": 2})
    assert r.status_code == 200
    assert len(r.json()) == 2

    r = client.get("/api/v1/shifts", params={"status": "open"})
    assert len(r.json()) == 5

    r = client.get("/api/v1/shifts", params={"status": "cancelled"})
    assert r.json() == []


def test_list_shifts_rejects_oversized_page(client):
    r = client.get("/api/v1/shifts", params={"limit": 5000})
    assert r.status_code == 422


def test_coverage_report_computes_fill_rate(client, site, worker):
    starts, ends = _window()
    shift = client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": starts, "ends_at": ends},
    ).json()
    starts2, ends2 = _window(offset_hours=72)
    client.post(
        "/api/v1/shifts",
        json={"site_id": site["id"], "role": "Nurse", "starts_at": starts2, "ends_at": ends2},
    )
    client.post(
        f"/api/v1/shifts/{shift['id']}/claim",
        json={"worker_id": worker["id"], "expected_version": 1},
    )

    r = client.get(f"/api/v1/sites/{site['id']}/coverage", params={"days": 7})
    assert r.status_code == 200
    body = r.json()
    assert body["total_shifts"] == 2
    assert body["fill_rate"] == 0.5


def test_duplicate_site_name_is_409(client, site):
    r = client.post("/api/v1/sites", json={"name": site["name"]})
    assert r.status_code == 409
