import os
from datetime import datetime, timedelta, timezone

import pytest

os.environ["SHIFTBOARD_DB_URL_OVERRIDE"] = "sqlite:///:memory:"
os.environ["SHIFTBOARD_ENVIRONMENT"] = "local"

from sqlalchemy.orm import sessionmaker  # noqa: E402

from worker.db import build_engine  # noqa: E402
from worker.config import get_settings  # noqa: E402
from worker.models import Base, Shift, ShiftStatus, Site, Worker  # noqa: E402

BASE = datetime(2026, 10, 5, 8, 0, tzinfo=timezone.utc)  # a Monday


@pytest.fixture
def session_factory():
    get_settings.cache_clear()
    engine = build_engine(get_settings())
    Base.metadata.create_all(engine)
    yield sessionmaker(bind=engine, expire_on_commit=False, future=True)
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture
def session(session_factory):
    s = session_factory()
    yield s
    s.close()


@pytest.fixture
def seeded(session):
    site = Site(id="site-1", name="Lahore Central", timezone="Asia/Karachi")
    worker = Worker(
        id="worker-1",
        external_id="emp-001",
        display_name="A. Rahman",
        max_weekly_hours=40,
        min_rest_hours=11,
    )
    session.add_all([site, worker])
    session.commit()
    return {"site": site, "worker": worker}


def make_shift(
    session,
    shift_id: str,
    offset_hours: float,
    length_hours: float = 8,
    worker_id: str | None = "worker-1",
    status: ShiftStatus = ShiftStatus.CLAIMED,
) -> Shift:
    shift = Shift(
        id=shift_id,
        site_id="site-1",
        role="Nurse",
        starts_at=BASE + timedelta(hours=offset_hours),
        ends_at=BASE + timedelta(hours=offset_hours + length_hours),
        status=status,
        assigned_worker_id=worker_id,
    )
    session.add(shift)
    session.commit()
    return shift
