"""Database engine construction.

Two modes:

1. Managed identity (Azure). azure-identity fetches an access token for
   https://database.windows.net/ and we inject it into the ODBC connection
   via SQL_COPT_SS_ACCESS_TOKEN. There is no password anywhere -- not in
   Key Vault, not in a Kubernetes Secret, not in the image.
2. Username/password (local docker-compose, and CI integration tests).

The engine is created lazily so importing the module never opens a socket,
which keeps unit tests fast and offline.
"""

from __future__ import annotations

import struct
from collections.abc import Iterator

from sqlalchemy import Engine, create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings, get_settings
from app.telemetry import get_logger

log = get_logger(__name__)

_SQL_COPT_SS_ACCESS_TOKEN = 1256
_AZURE_SQL_SCOPE = "https://database.windows.net/.default"

_engine: Engine | None = None
_SessionFactory: sessionmaker[Session] | None = None


def _attach_managed_identity(engine: Engine) -> None:
    from azure.identity import DefaultAzureCredential

    credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)

    @event.listens_for(engine, "do_connect")
    def _provide_token(dialect, conn_rec, cargs, cparams):  # noqa: ANN001
        token = credential.get_token(_AZURE_SQL_SCOPE).token
        raw = token.encode("utf-16-le")
        cparams["attrs_before"] = {
            _SQL_COPT_SS_ACCESS_TOKEN: struct.pack("<i", len(raw)) + raw
        }


def build_engine(settings: Settings | None = None) -> Engine:
    settings = settings or get_settings()
    url = settings.sqlalchemy_url

    kwargs: dict = {"echo": settings.db_echo, "pool_pre_ping": True, "future": True}
    if url.startswith("sqlite"):
        # Unit tests: shared in-memory database across the whole session.
        from sqlalchemy.pool import StaticPool

        kwargs.update(connect_args={"check_same_thread": False}, poolclass=StaticPool)
    else:
        kwargs.update(pool_size=5, max_overflow=10, pool_recycle=1800)

    engine = create_engine(url, **kwargs)

    if settings.db_use_managed_identity and not url.startswith("sqlite"):
        _attach_managed_identity(engine)
        log.info("db_auth_mode", mode="workload_identity")
    else:
        log.info("db_auth_mode", mode="password" if not url.startswith("sqlite") else "sqlite")

    return engine


def get_engine() -> Engine:
    global _engine, _SessionFactory
    if _engine is None:
        _engine = build_engine()
        _SessionFactory = sessionmaker(bind=_engine, expire_on_commit=False, future=True)
    return _engine


def get_session_factory() -> sessionmaker[Session]:
    get_engine()
    assert _SessionFactory is not None
    return _SessionFactory


def reset_engine() -> None:
    """Used by tests to rebuild the engine after changing settings."""
    global _engine, _SessionFactory
    if _engine is not None:
        _engine.dispose()
    _engine = None
    _SessionFactory = None
    get_settings.cache_clear()


def get_db() -> Iterator[Session]:
    """FastAPI dependency. One session per request, always closed."""
    factory = get_session_factory()
    session = factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
