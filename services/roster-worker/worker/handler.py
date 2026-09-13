"""Event handling: load context, run rules, persist findings, idempotently."""

from __future__ import annotations

import json
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from worker.metrics import CONFLICTS_DETECTED, EVENT_LAG_SECONDS
from worker.models import Conflict, ProcessedEvent, Shift, ShiftStatus, Worker
from worker.rules import ShiftWindow, WorkerPolicy, evaluate
from worker.telemetry import get_logger

log = get_logger(__name__)

HANDLED_EVENT_TYPES = {"shift.created", "shift.claimed", "shift.cancelled"}


class TransientError(RuntimeError):
    """Raised when the message should be abandoned and redelivered."""


class PermanentError(ValueError):
    """Raised when the message can never succeed and should be dead-lettered."""


def parse_event(raw: str | bytes) -> dict[str, Any]:
    try:
        event = json.loads(raw)
    except (json.JSONDecodeError, TypeError) as exc:
        raise PermanentError(f"message body is not valid JSON: {exc}") from exc

    for field in ("event_id", "event_type", "data"):
        if field not in event:
            raise PermanentError(f"message is missing required field '{field}'")
    if not isinstance(event["data"], dict):
        raise PermanentError("field 'data' must be an object")
    return event


def _record_lag(event: dict[str, Any]) -> None:
    occurred = event.get("occurred_at")
    if not occurred:
        return
    try:
        then = datetime.fromisoformat(occurred)
    except ValueError:
        return
    if then.tzinfo is None:
        then = then.replace(tzinfo=UTC)
    EVENT_LAG_SECONDS.observe(max(0.0, (datetime.now(UTC) - then).total_seconds()))


def already_processed(session: Session, event_id: str) -> bool:
    return session.get(ProcessedEvent, event_id) is not None


def mark_processed(session: Session, event_id: str) -> None:
    session.merge(ProcessedEvent(event_id=event_id, processed_at=datetime.now(UTC)))


def _rescan_shift(session: Session, shift_id: str) -> int:
    """Recompute conflicts for one shift. Returns the number written."""
    shift = session.get(Shift, shift_id)
    if shift is None:
        log.info("shift_missing_skip", shift_id=shift_id)
        return 0

    # Findings are always fully replaced, never appended. That makes the scan
    # idempotent at the data level too, independent of the event ledger.
    session.execute(delete(Conflict).where(Conflict.shift_id == shift_id))

    if shift.status is ShiftStatus.CANCELLED or shift.assigned_worker_id is None:
        return 0

    worker = session.get(Worker, shift.assigned_worker_id)
    if worker is None:
        raise PermanentError(f"shift {shift_id} references unknown worker")

    others = list(
        session.scalars(
            select(Shift).where(
                Shift.assigned_worker_id == worker.id,
                Shift.id != shift.id,
                Shift.status.in_([ShiftStatus.CLAIMED, ShiftStatus.CONFIRMED]),
            )
        )
    )

    subject = ShiftWindow(shift.id, shift.starts_at, shift.ends_at)
    windows = [ShiftWindow(s.id, s.starts_at, s.ends_at) for s in others]
    policy = WorkerPolicy(worker.id, worker.max_weekly_hours, worker.min_rest_hours)

    findings = evaluate(subject, windows, policy)
    for finding in findings:
        session.add(Conflict(shift_id=shift.id, kind=finding.kind, detail=finding.detail))
        CONFLICTS_DETECTED.labels(kind=finding.kind).inc()

    if findings:
        log.warning(
            "conflicts_detected",
            shift_id=shift.id,
            worker_id=worker.id,
            count=len(findings),
            kinds=[f.kind for f in findings],
        )
    return len(findings)


def handle_event(session: Session, event: dict[str, Any]) -> str:
    """Returns one of: processed, duplicate, ignored."""
    event_id = event["event_id"]
    event_type = event["event_type"]

    if event_type not in HANDLED_EVENT_TYPES:
        log.info("event_ignored", event_type=event_type, event_id=event_id)
        return "ignored"

    if already_processed(session, event_id):
        log.info("event_duplicate", event_id=event_id, event_type=event_type)
        return "duplicate"

    _record_lag(event)

    shift_id = event["data"].get("shift_id")
    if not shift_id:
        raise PermanentError("event data is missing 'shift_id'")

    _rescan_shift(session, shift_id)
    mark_processed(session, event_id)
    return "processed"
