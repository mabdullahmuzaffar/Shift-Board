"""Request/response contracts. Kept separate from ORM models on purpose so the
public API can evolve without a database migration and vice versa."""

from __future__ import annotations

from datetime import datetime, timedelta

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.models import ConflictKind, ShiftStatus

MAX_SHIFT_HOURS = 16


class SiteIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    timezone: str = Field(default="UTC", max_length=64)


class SiteOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    name: str
    timezone: str


class WorkerIn(BaseModel):
    external_id: str = Field(min_length=1, max_length=120)
    display_name: str = Field(min_length=1, max_length=120)
    max_weekly_hours: int = Field(default=40, gt=0, le=80)
    min_rest_hours: int = Field(default=11, ge=0, le=24)


class WorkerOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    external_id: str
    display_name: str
    max_weekly_hours: int
    min_rest_hours: int


class ShiftIn(BaseModel):
    site_id: str
    role: str = Field(min_length=1, max_length=80)
    starts_at: datetime
    ends_at: datetime

    @field_validator("starts_at", "ends_at")
    @classmethod
    def _require_tz(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            raise ValueError("timestamps must be timezone-aware (use ISO-8601 with offset)")
        return v

    @model_validator(mode="after")
    def _check_window(self):
        if self.ends_at <= self.starts_at:
            raise ValueError("ends_at must be after starts_at")
        if self.ends_at - self.starts_at > timedelta(hours=MAX_SHIFT_HOURS):
            raise ValueError(f"a single shift may not exceed {MAX_SHIFT_HOURS} hours")
        return self


class ConflictOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    kind: ConflictKind
    detail: str
    detected_at: datetime


class ShiftOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: str
    site_id: str
    role: str
    starts_at: datetime
    ends_at: datetime
    status: ShiftStatus
    assigned_worker_id: str | None
    version: int
    conflicts: list[ConflictOut] = []


class ClaimIn(BaseModel):
    worker_id: str
    # Optimistic concurrency: the client echoes the version it read. Two workers
    # racing for the same open shift means one gets a 409 instead of both winning.
    expected_version: int = Field(ge=1)


class HealthOut(BaseModel):
    status: str
    service: str
    environment: str
    checks: dict[str, str] = {}
