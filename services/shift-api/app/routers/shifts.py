"""Shift, site and worker endpoints."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from app.db import get_db
from app.messaging import Publisher, get_publisher
from app.metrics import DB_QUERY_SECONDS, OPEN_SHIFTS, SHIFT_CLAIMS, SHIFTS_CREATED
from app.models import Shift, ShiftStatus, Site, Worker
from app.schemas import ClaimIn, ShiftIn, ShiftOut, SiteIn, SiteOut, WorkerIn, WorkerOut
from app.security import ROLE_SCHEDULER, ROLE_WORKER, Principal, current_principal, require_role
from app.telemetry import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/api/v1", tags=["shifts"])

MAX_PAGE_SIZE = 200


# --------------------------------------------------------------------------- sites
@router.post("/sites", response_model=SiteOut, status_code=status.HTTP_201_CREATED)
def create_site(
    body: SiteIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_role(ROLE_SCHEDULER)),
) -> Site:
    site = Site(name=body.name, timezone=body.timezone)
    db.add(site)
    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "site name already exists") from exc
    return site


@router.get("/sites", response_model=list[SiteOut])
def list_sites(
    db: Session = Depends(get_db), _: Principal = Depends(current_principal)
) -> list[Site]:
    return list(db.scalars(select(Site).order_by(Site.name)))


# ------------------------------------------------------------------------- workers
@router.post("/workers", response_model=WorkerOut, status_code=status.HTTP_201_CREATED)
def create_worker(
    body: WorkerIn,
    db: Session = Depends(get_db),
    _: Principal = Depends(require_role(ROLE_SCHEDULER)),
) -> Worker:
    worker = Worker(**body.model_dump())
    db.add(worker)
    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "external_id already exists") from exc
    return worker


# -------------------------------------------------------------------------- shifts
@router.post("/shifts", response_model=ShiftOut, status_code=status.HTTP_201_CREATED)
def create_shift(
    body: ShiftIn,
    db: Session = Depends(get_db),
    publisher: Publisher = Depends(get_publisher),
    _: Principal = Depends(require_role(ROLE_SCHEDULER)),
) -> Shift:
    if db.get(Site, body.site_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "site not found")

    shift = Shift(
        site_id=body.site_id,
        role=body.role,
        starts_at=body.starts_at,
        ends_at=body.ends_at,
        status=ShiftStatus.OPEN,
    )
    db.add(shift)
    db.flush()

    SHIFTS_CREATED.labels(site_id=body.site_id).inc()
    publisher.publish(
        "shift.created",
        {
            "shift_id": shift.id,
            "site_id": shift.site_id,
            "starts_at": shift.starts_at.isoformat(),
            "ends_at": shift.ends_at.isoformat(),
        },
    )
    log.info("shift_created", shift_id=shift.id, site_id=shift.site_id)
    return shift


@router.get("/shifts", response_model=list[ShiftOut])
def list_shifts(
    db: Session = Depends(get_db),
    _: Principal = Depends(current_principal),
    site_id: str | None = None,
    shift_status: ShiftStatus | None = Query(default=None, alias="status"),
    starts_after: datetime | None = None,
    limit: int = Query(default=50, ge=1, le=MAX_PAGE_SIZE),
    offset: int = Query(default=0, ge=0),
) -> list[Shift]:
    stmt = select(Shift).options(selectinload(Shift.conflicts))
    if site_id:
        stmt = stmt.where(Shift.site_id == site_id)
    if shift_status:
        stmt = stmt.where(Shift.status == shift_status)
    if starts_after:
        stmt = stmt.where(Shift.starts_at >= starts_after)
    stmt = stmt.order_by(Shift.starts_at).limit(limit).offset(offset)

    with DB_QUERY_SECONDS.labels(query="list_shifts").time():
        rows = list(db.scalars(stmt))

    if site_id:
        open_count = db.scalar(
            select(func.count())
            .select_from(Shift)
            .where(Shift.site_id == site_id, Shift.status == ShiftStatus.OPEN)
        )
        OPEN_SHIFTS.labels(site_id=site_id).set(open_count or 0)

    return rows


@router.get("/shifts/{shift_id}", response_model=ShiftOut)
def get_shift(
    shift_id: str,
    db: Session = Depends(get_db),
    _: Principal = Depends(current_principal),
) -> Shift:
    shift = db.scalar(
        select(Shift).where(Shift.id == shift_id).options(selectinload(Shift.conflicts))
    )
    if shift is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "shift not found")
    return shift


@router.post("/shifts/{shift_id}/claim", response_model=ShiftOut)
def claim_shift(
    shift_id: str,
    body: ClaimIn,
    db: Session = Depends(get_db),
    publisher: Publisher = Depends(get_publisher),
    _: Principal = Depends(require_role(ROLE_WORKER)),
) -> Shift:
    shift = db.get(Shift, shift_id)
    if shift is None:
        SHIFT_CLAIMS.labels(outcome="not_found").inc()
        raise HTTPException(status.HTTP_404_NOT_FOUND, "shift not found")

    if db.get(Worker, body.worker_id) is None:
        SHIFT_CLAIMS.labels(outcome="not_found").inc()
        raise HTTPException(status.HTTP_404_NOT_FOUND, "worker not found")

    if shift.version != body.expected_version:
        SHIFT_CLAIMS.labels(outcome="conflict").inc()
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"shift was modified (expected version {body.expected_version}, "
            f"current {shift.version}); re-read and retry",
        )

    if shift.status is not ShiftStatus.OPEN:
        SHIFT_CLAIMS.labels(outcome="conflict").inc()
        raise HTTPException(status.HTTP_409_CONFLICT, f"shift is {shift.status.value}")

    shift.status = ShiftStatus.CLAIMED
    shift.assigned_worker_id = body.worker_id
    shift.version += 1
    db.flush()

    SHIFT_CLAIMS.labels(outcome="accepted").inc()
    publisher.publish(
        "shift.claimed",
        {
            "shift_id": shift.id,
            "worker_id": body.worker_id,
            "starts_at": shift.starts_at.isoformat(),
            "ends_at": shift.ends_at.isoformat(),
        },
    )
    log.info("shift_claimed", shift_id=shift.id, worker_id=body.worker_id)
    return shift


@router.delete("/shifts/{shift_id}", response_model=ShiftOut)
def cancel_shift(
    shift_id: str,
    db: Session = Depends(get_db),
    publisher: Publisher = Depends(get_publisher),
    _: Principal = Depends(require_role(ROLE_SCHEDULER)),
) -> Shift:
    shift = db.get(Shift, shift_id)
    if shift is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "shift not found")
    if shift.status is ShiftStatus.CANCELLED:
        return shift

    shift.status = ShiftStatus.CANCELLED
    shift.version += 1
    db.flush()
    publisher.publish("shift.cancelled", {"shift_id": shift.id})
    log.info("shift_cancelled", shift_id=shift.id)
    return shift


@router.get("/sites/{site_id}/coverage")
def coverage_report(
    site_id: str,
    days: int = Query(default=7, ge=1, le=31),
    db: Session = Depends(get_db),
    _: Principal = Depends(current_principal),
) -> dict:
    """Simple operational read used by the web dashboard and the k6 smoke test."""
    if db.get(Site, site_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "site not found")

    window_start = datetime.now(UTC)
    window_end = window_start + timedelta(days=days)

    rows = db.execute(
        select(Shift.status, func.count())
        .where(
            Shift.site_id == site_id,
            Shift.starts_at >= window_start,
            Shift.starts_at < window_end,
        )
        .group_by(Shift.status)
    ).all()

    by_status = {str(status_.value): count for status_, count in rows}
    total = sum(by_status.values())
    filled = by_status.get("claimed", 0) + by_status.get("confirmed", 0)

    return {
        "site_id": site_id,
        "window_days": days,
        "total_shifts": total,
        "by_status": by_status,
        "fill_rate": round(filled / total, 4) if total else 0.0,
    }
