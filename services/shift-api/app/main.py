"""Application entrypoint."""

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from app.config import get_settings
from app.db import get_engine
from app.routers import health, shifts
from app.telemetry import configure_logging, configure_tracing, get_logger

settings = get_settings()
configure_logging(settings.service_name, settings.environment, settings.log_level)
log = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("startup", environment=settings.environment, version=app.version)
    engine = None
    try:
        engine = get_engine()
    except Exception as exc:
        # Do not crash-loop on a transient database outage; readiness will
        # report unhealthy and Argo Rollouts / the Deployment will hold.
        log.error("engine_init_failed", error=str(exc))
    configure_tracing(app, engine, settings)
    yield
    log.info("shutdown")


app = FastAPI(
    title="ShiftBoard Shift API",
    version="1.0.0",
    description="Workforce shift scheduling for multi-site operators.",
    lifespan=lifespan,
    docs_url="/docs",
    openapi_url="/openapi.json",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if settings.environment != "prod" else [],
    allow_credentials=False,
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(shifts.router)

if settings.metrics_enabled:
    Instrumentator(
        should_group_status_codes=False,
        excluded_handlers=["/metrics", "/healthz", "/readyz", "/startupz"],
    ).instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


@app.get("/", include_in_schema=False)
def root() -> dict:
    return {"service": settings.service_name, "version": app.version, "docs": "/docs"}
