"""Liveness, readiness and startup probes.

The distinction matters and is a common interview question:

  /healthz  -- liveness. Process is alive. Never touches the database,
               because a slow database must not cause Kubernetes to kill
               and restart every pod at once (a classic cascading failure).
  /readyz   -- readiness. Can this pod serve traffic right now? Checks the
               database with a short timeout so a broken pod is pulled from
               the Service endpoints without being restarted.
  /startupz -- startup. Gives slow first-connection setup time to finish
               before liveness begins counting failures.
"""

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import get_db
from app.schemas import HealthOut

router = APIRouter(tags=["health"])


@router.get("/healthz", response_model=HealthOut)
def liveness(settings: Settings = Depends(get_settings)) -> HealthOut:
    return HealthOut(status="ok", service=settings.service_name, environment=settings.environment)


@router.get("/readyz", response_model=HealthOut)
def readiness(
    response: Response,
    settings: Settings = Depends(get_settings),
    db: Session = Depends(get_db),
) -> HealthOut:
    checks: dict[str, str] = {}
    healthy = True
    try:
        db.execute(text("SELECT 1"))
        checks["database"] = "ok"
    except Exception as exc:
        checks["database"] = f"error: {type(exc).__name__}"
        healthy = False

    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

    return HealthOut(
        status="ok" if healthy else "degraded",
        service=settings.service_name,
        environment=settings.environment,
        checks=checks,
    )


@router.get("/startupz", response_model=HealthOut)
def startup(
    response: Response,
    settings: Settings = Depends(get_settings),
    db: Session = Depends(get_db),
) -> HealthOut:
    return readiness(response=response, settings=settings, db=db)
