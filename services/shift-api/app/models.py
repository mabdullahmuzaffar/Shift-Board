"""SQLAlchemy ORM models.

Domain: a retail/healthcare operator running many sites needs to publish
staff shifts, let workers claim open shifts, and detect scheduling conflicts
(double-booking, insufficient rest between shifts, exceeding weekly hours).
Conflict detection is deliberately pushed to an async worker so the API stays
fast and the expensive rule evaluation can be retried independently.
"""

from __future__ import annotations

import enum
import uuid
from datetime import UTC, datetime

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _new_id() -> str:
    return str(uuid.uuid4())


class Base(DeclarativeBase):
    pass


class ShiftStatus(str, enum.Enum):
    OPEN = "open"
    CLAIMED = "claimed"
    CONFIRMED = "confirmed"
    CANCELLED = "cancelled"


class ConflictKind(str, enum.Enum):
    OVERLAP = "overlap"
    INSUFFICIENT_REST = "insufficient_rest"
    WEEKLY_HOURS_EXCEEDED = "weekly_hours_exceeded"


class Site(Base):
    __tablename__ = "sites"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_id)
    name: Mapped[str] = mapped_column(String(120), nullable=False, unique=True)
    timezone: Mapped[str] = mapped_column(String(64), nullable=False, default="UTC")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    shifts: Mapped[list[Shift]] = relationship(back_populates="site")


class Worker(Base):
    __tablename__ = "workers"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_id)
    external_id: Mapped[str] = mapped_column(String(120), nullable=False, unique=True)
    display_name: Mapped[str] = mapped_column(String(120), nullable=False)
    max_weekly_hours: Mapped[int] = mapped_column(Integer, nullable=False, default=40)
    min_rest_hours: Mapped[int] = mapped_column(Integer, nullable=False, default=11)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    __table_args__ = (
        CheckConstraint("max_weekly_hours > 0", name="ck_worker_weekly_hours"),
        CheckConstraint("min_rest_hours >= 0", name="ck_worker_rest_hours"),
    )


class Shift(Base):
    __tablename__ = "shifts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_id)
    site_id: Mapped[str] = mapped_column(ForeignKey("sites.id"), nullable=False)
    role: Mapped[str] = mapped_column(String(80), nullable=False)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    status: Mapped[ShiftStatus] = mapped_column(
        Enum(ShiftStatus, native_enum=False, length=20),
        nullable=False,
        default=ShiftStatus.OPEN,
    )
    assigned_worker_id: Mapped[str | None] = mapped_column(
        ForeignKey("workers.id"), nullable=True
    )
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_utcnow, onupdate=_utcnow
    )

    site: Mapped[Site] = relationship(back_populates="shifts")
    conflicts: Mapped[list[Conflict]] = relationship(
        back_populates="shift", cascade="all, delete-orphan"
    )

    __table_args__ = (
        CheckConstraint("ends_at > starts_at", name="ck_shift_time_order"),
        Index("ix_shifts_site_start", "site_id", "starts_at"),
        Index("ix_shifts_worker_start", "assigned_worker_id", "starts_at"),
        Index("ix_shifts_status", "status"),
    )


class Conflict(Base):
    """Written only by roster-worker. The API reads but never creates these."""

    __tablename__ = "conflicts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=_new_id)
    shift_id: Mapped[str] = mapped_column(
        ForeignKey("shifts.id", ondelete="CASCADE"), nullable=False
    )
    kind: Mapped[ConflictKind] = mapped_column(
        Enum(ConflictKind, native_enum=False, length=32), nullable=False
    )
    detail: Mapped[str] = mapped_column(Text, nullable=False)
    detected_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)

    shift: Mapped[Shift] = relationship(back_populates="conflicts")

    __table_args__ = (Index("ix_conflicts_shift", "shift_id"),)


class ProcessedEvent(Base):
    """Idempotency ledger for roster-worker.

    Service Bus gives at-least-once delivery, so the worker must tolerate
    duplicates. It records every event id it has fully processed and skips
    replays. Without this, a redelivery would duplicate conflict rows.
    """

    __tablename__ = "processed_events"

    event_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    processed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_utcnow)
