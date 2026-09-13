"""Regression tests for the naive/aware datetime boundary.

SQL Server `datetime2` (what DateTime(timezone=True) maps to) stores no UTC
offset, so values written as aware come back naive. Before `as_utc` existed,
the first rule evaluation on data loaded from a fresh session raised
`TypeError: can't compare offset-naive and offset-aware datetimes`.
"""

from datetime import datetime, timedelta, timezone

from worker.rules import ShiftWindow, WorkerPolicy, as_utc, evaluate

POLICY = WorkerPolicy("w1", 40, 11)


def test_as_utc_attaches_utc_to_naive():
    naive = datetime(2026, 10, 5, 8, 0)
    assert as_utc(naive).tzinfo is timezone.utc


def test_as_utc_preserves_existing_offset():
    aware = datetime(2026, 10, 5, 8, 0, tzinfo=timezone(timedelta(hours=5)))
    assert as_utc(aware).utcoffset() == timedelta(hours=5)


def test_shift_window_normalises_naive_inputs():
    w = ShiftWindow("a", datetime(2026, 10, 5, 8, 0), datetime(2026, 10, 5, 16, 0))
    assert w.starts_at.tzinfo is timezone.utc
    assert w.hours == 8.0


def test_mixed_naive_and_aware_can_be_compared():
    """The exact crash that this guard prevents."""
    from_db = ShiftWindow("db", datetime(2026, 10, 5, 8, 0), datetime(2026, 10, 5, 16, 0))
    in_memory = ShiftWindow(
        "mem",
        datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc),
        datetime(2026, 10, 5, 20, 0, tzinfo=timezone.utc),
    )
    findings = evaluate(in_memory, [from_db], POLICY)
    assert [f.kind for f in findings] == ["overlap"]
