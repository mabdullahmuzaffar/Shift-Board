"""initial schema: sites, workers, shifts, conflicts, processed_events

Revision ID: 0001
Revises:
Create Date: 2026-09-11
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "sites",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("name", sa.String(120), nullable=False, unique=True),
        sa.Column("timezone", sa.String(64), nullable=False, server_default="UTC"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )

    op.create_table(
        "workers",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("external_id", sa.String(120), nullable=False, unique=True),
        sa.Column("display_name", sa.String(120), nullable=False),
        sa.Column("max_weekly_hours", sa.Integer(), nullable=False, server_default="40"),
        sa.Column("min_rest_hours", sa.Integer(), nullable=False, server_default="11"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("max_weekly_hours > 0", name="ck_worker_weekly_hours"),
        sa.CheckConstraint("min_rest_hours >= 0", name="ck_worker_rest_hours"),
    )

    op.create_table(
        "shifts",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("site_id", sa.String(36), sa.ForeignKey("sites.id"), nullable=False),
        sa.Column("role", sa.String(80), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="open"),
        sa.Column(
            "assigned_worker_id", sa.String(36), sa.ForeignKey("workers.id"), nullable=True
        ),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("ends_at > starts_at", name="ck_shift_time_order"),
    )
    op.create_index("ix_shifts_site_start", "shifts", ["site_id", "starts_at"])
    op.create_index("ix_shifts_worker_start", "shifts", ["assigned_worker_id", "starts_at"])
    op.create_index("ix_shifts_status", "shifts", ["status"])

    op.create_table(
        "conflicts",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column(
            "shift_id",
            sa.String(36),
            sa.ForeignKey("shifts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("detail", sa.Text(), nullable=False),
        sa.Column("detected_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_conflicts_shift", "conflicts", ["shift_id"])

    op.create_table(
        "processed_events",
        sa.Column("event_id", sa.String(64), primary_key=True),
        sa.Column("processed_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("processed_events")
    op.drop_index("ix_conflicts_shift", table_name="conflicts")
    op.drop_table("conflicts")
    op.drop_index("ix_shifts_status", table_name="shifts")
    op.drop_index("ix_shifts_worker_start", table_name="shifts")
    op.drop_index("ix_shifts_site_start", table_name="shifts")
    op.drop_table("shifts")
    op.drop_table("workers")
    op.drop_table("sites")
