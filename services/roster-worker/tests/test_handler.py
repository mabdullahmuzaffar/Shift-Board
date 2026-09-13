"""Handler tests: idempotency, dead-lettering, and conflict persistence."""

import json
from datetime import datetime, timezone

import pytest
from sqlalchemy import func, select

from tests.conftest import make_shift
from worker.handler import PermanentError, handle_event, parse_event
from worker.main import process_one
from worker.models import Conflict, ProcessedEvent, ShiftStatus


def event(event_type: str, shift_id: str, event_id: str = "evt-1") -> dict:
    return {
        "event_id": event_id,
        "event_type": event_type,
        "occurred_at": datetime.now(timezone.utc).isoformat(),
        "schema_version": 1,
        "data": {"shift_id": shift_id},
    }


# ----------------------------------------------------------------- parse_event
def test_parse_rejects_non_json():
    with pytest.raises(PermanentError, match="not valid JSON"):
        parse_event("this is not json{")


def test_parse_rejects_missing_fields():
    with pytest.raises(PermanentError, match="missing required field"):
        parse_event(json.dumps({"event_id": "e1", "event_type": "shift.created"}))


def test_parse_rejects_non_object_data():
    with pytest.raises(PermanentError, match="must be an object"):
        parse_event(
            json.dumps({"event_id": "e1", "event_type": "shift.created", "data": "nope"})
        )


def test_parse_accepts_valid_envelope():
    parsed = parse_event(json.dumps(event("shift.created", "s1")))
    assert parsed["event_type"] == "shift.created"


# ---------------------------------------------------------------- handle_event
def test_unknown_event_type_is_ignored(session, seeded):
    assert handle_event(session, event("billing.invoiced", "s1")) == "ignored"


def test_missing_shift_id_is_permanent(session, seeded):
    bad = event("shift.created", "s1")
    bad["data"] = {}
    with pytest.raises(PermanentError, match="missing 'shift_id'"):
        handle_event(session, bad)


def test_event_for_unknown_shift_is_processed_not_failed(session, seeded):
    """A cancelled-then-deleted shift must not poison the queue forever."""
    assert handle_event(session, event("shift.created", "ghost")) == "processed"


def test_duplicate_event_is_skipped(session, seeded):
    make_shift(session, "s1", offset_hours=0)
    assert handle_event(session, event("shift.claimed", "s1")) == "processed"
    session.commit()
    assert handle_event(session, event("shift.claimed", "s1")) == "duplicate"


def test_processed_ledger_is_written(session, seeded):
    make_shift(session, "s1", offset_hours=0)
    handle_event(session, event("shift.claimed", "s1", event_id="evt-abc"))
    session.commit()
    assert session.get(ProcessedEvent, "evt-abc") is not None


def test_open_shift_has_no_conflicts(session, seeded):
    make_shift(session, "s1", offset_hours=0, worker_id=None, status=ShiftStatus.OPEN)
    handle_event(session, event("shift.created", "s1"))
    session.commit()
    assert session.scalar(select(func.count()).select_from(Conflict)) == 0


def test_overlapping_claim_writes_conflict(session, seeded):
    make_shift(session, "s1", offset_hours=0, length_hours=8)
    make_shift(session, "s2", offset_hours=4, length_hours=8)
    handle_event(session, event("shift.claimed", "s2"))
    session.commit()

    conflicts = list(session.scalars(select(Conflict).where(Conflict.shift_id == "s2")))
    kinds = {c.kind for c in conflicts}
    assert "overlap" in kinds


def test_rescan_replaces_rather_than_appends(session, seeded):
    """Re-running the scan for the same shift must not duplicate rows."""
    make_shift(session, "s1", offset_hours=0, length_hours=8)
    make_shift(session, "s2", offset_hours=4, length_hours=8)

    handle_event(session, event("shift.claimed", "s2", event_id="e1"))
    session.commit()
    first = session.scalar(
        select(func.count()).select_from(Conflict).where(Conflict.shift_id == "s2")
    )

    handle_event(session, event("shift.claimed", "s2", event_id="e2"))
    session.commit()
    second = session.scalar(
        select(func.count()).select_from(Conflict).where(Conflict.shift_id == "s2")
    )

    assert first == second and first > 0


def test_cancelling_clears_existing_conflicts(session, seeded):
    make_shift(session, "s1", offset_hours=0, length_hours=8)
    shift2 = make_shift(session, "s2", offset_hours=4, length_hours=8)
    handle_event(session, event("shift.claimed", "s2", event_id="e1"))
    session.commit()
    assert session.scalar(select(func.count()).select_from(Conflict)) > 0

    shift2.status = ShiftStatus.CANCELLED
    session.commit()
    handle_event(session, event("shift.cancelled", "s2", event_id="e2"))
    session.commit()

    assert (
        session.scalar(
            select(func.count()).select_from(Conflict).where(Conflict.shift_id == "s2")
        )
        == 0
    )


def test_insufficient_rest_persisted(session, seeded):
    make_shift(session, "s1", offset_hours=0, length_hours=8)     # ends 16:00
    make_shift(session, "s2", offset_hours=12, length_hours=8)    # starts 20:00
    handle_event(session, event("shift.claimed", "s2"))
    session.commit()

    kinds = {
        c.kind for c in session.scalars(select(Conflict).where(Conflict.shift_id == "s2"))
    }
    assert "insufficient_rest" in kinds


def test_shift_with_unknown_worker_is_dead_lettered(session, seeded):
    make_shift(session, "s1", offset_hours=0, worker_id="ghost-worker")
    with pytest.raises(PermanentError, match="unknown worker"):
        handle_event(session, event("shift.claimed", "s1"))


# --------------------------------------------------------------- process_one
def test_process_one_commits_and_reports_outcome(session_factory, session, seeded):
    make_shift(session, "s1", offset_hours=0)
    outcome = process_one(session_factory, json.dumps(event("shift.claimed", "s1")))
    assert outcome == "processed"

    verify = session_factory()
    assert verify.get(ProcessedEvent, "evt-1") is not None
    verify.close()


def test_process_one_propagates_permanent_error(session_factory, seeded):
    with pytest.raises(PermanentError):
        process_one(session_factory, "not-json")
