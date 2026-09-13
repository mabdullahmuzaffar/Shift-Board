"""Scheduling conflict rules.

Pure functions over data already loaded from the database. Keeping them free
of I/O is what makes them cheap to unit test -- the whole rule engine is
covered without a database, a queue, or a cluster.

Three rules, all real constraints in workforce management:

  OVERLAP                -- a worker assigned to two shifts that intersect.
  INSUFFICIENT_REST      -- gap between consecutive shifts below the worker's
                            contractual minimum rest (EU Working Time
                            Directive style, default 11 hours).
  WEEKLY_HOURS_EXCEEDED  -- assigned hours in the ISO week containing the
                            shift exceed the worker's contracted maximum.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta


def as_utc(value: datetime) -> datetime:
    """Coerce a datetime to timezone-aware UTC.

    This is not defensive padding -- it is required. Our columns are declared
    ``DateTime(timezone=True)``, which SQLAlchemy maps to SQL Server
    ``datetime2``. ``datetime2`` stores no offset, so a value written as
    aware UTC is read back *naive*. Comparing a freshly-constructed aware
    datetime with a naive one loaded from the database raises TypeError, so
    every datetime entering the rule engine is normalised here at the
    boundary. Values are always written as UTC (see models._utcnow), so
    attaching UTC to a naive value is correct rather than a guess.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


@dataclass(frozen=True)
class ShiftWindow:
    shift_id: str
    starts_at: datetime
    ends_at: datetime

    def __post_init__(self) -> None:
        object.__setattr__(self, "starts_at", as_utc(self.starts_at))
        object.__setattr__(self, "ends_at", as_utc(self.ends_at))

    @property
    def hours(self) -> float:
        return (self.ends_at - self.starts_at).total_seconds() / 3600.0

    def overlaps(self, other: ShiftWindow) -> bool:
        return self.starts_at < other.ends_at and other.starts_at < self.ends_at


@dataclass(frozen=True)
class WorkerPolicy:
    worker_id: str
    max_weekly_hours: int
    min_rest_hours: int


@dataclass(frozen=True)
class Finding:
    kind: str
    detail: str


KIND_OVERLAP = "overlap"
KIND_INSUFFICIENT_REST = "insufficient_rest"
KIND_WEEKLY_HOURS_EXCEEDED = "weekly_hours_exceeded"


def _iso_week_bounds(moment: datetime) -> tuple[datetime, datetime]:
    start_of_day = moment.replace(hour=0, minute=0, second=0, microsecond=0)
    monday = start_of_day - timedelta(days=start_of_day.weekday())
    return monday, monday + timedelta(days=7)


def find_overlaps(subject: ShiftWindow, others: list[ShiftWindow]) -> list[Finding]:
    findings: list[Finding] = []
    for other in others:
        if other.shift_id == subject.shift_id:
            continue
        if subject.overlaps(other):
            findings.append(
                Finding(
                    kind=KIND_OVERLAP,
                    detail=(
                        f"overlaps shift {other.shift_id} "
                        f"({other.starts_at.isoformat()} -> {other.ends_at.isoformat()})"
                    ),
                )
            )
    return findings


def find_insufficient_rest(
    subject: ShiftWindow, others: list[ShiftWindow], policy: WorkerPolicy
) -> list[Finding]:
    findings: list[Finding] = []
    min_rest = timedelta(hours=policy.min_rest_hours)
    if min_rest <= timedelta(0):
        return findings

    for other in others:
        if other.shift_id == subject.shift_id or subject.overlaps(other):
            continue
        if other.ends_at <= subject.starts_at:
            gap = subject.starts_at - other.ends_at
            neighbour = "before"
        elif subject.ends_at <= other.starts_at:
            gap = other.starts_at - subject.ends_at
            neighbour = "after"
        else:  # pragma: no cover - covered by the overlap guard above
            continue

        if gap < min_rest:
            hours = round(gap.total_seconds() / 3600.0, 2)
            findings.append(
                Finding(
                    kind=KIND_INSUFFICIENT_REST,
                    detail=(
                        f"only {hours}h rest {neighbour} shift {other.shift_id}; "
                        f"policy requires {policy.min_rest_hours}h"
                    ),
                )
            )
    return findings


def find_weekly_hours_exceeded(
    subject: ShiftWindow, others: list[ShiftWindow], policy: WorkerPolicy
) -> list[Finding]:
    week_start, week_end = _iso_week_bounds(subject.starts_at)

    total = subject.hours
    for other in others:
        if other.shift_id == subject.shift_id:
            continue
        if week_start <= other.starts_at < week_end:
            total += other.hours

    if total > policy.max_weekly_hours:
        return [
            Finding(
                kind=KIND_WEEKLY_HOURS_EXCEEDED,
                detail=(
                    f"week of {week_start.date().isoformat()} totals "
                    f"{round(total, 2)}h against a {policy.max_weekly_hours}h maximum"
                ),
            )
        ]
    return []


def evaluate(
    subject: ShiftWindow, others: list[ShiftWindow], policy: WorkerPolicy
) -> list[Finding]:
    """Run every rule. Order is stable so tests and snapshots are deterministic."""
    return [
        *find_overlaps(subject, others),
        *find_insufficient_rest(subject, others, policy),
        *find_weekly_hours_exceeded(subject, others, policy),
    ]
