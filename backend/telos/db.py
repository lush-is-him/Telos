"""Server-side schema. Mirrors the phone's SQLite tables column-for-column,
but with real types (DATE, TIMESTAMPTZ, BOOLEAN) so analysis in Postgres is
pleasant. Conversion to and from the phone's text encoding lives in
`to_db` / `to_wire`.
"""

from __future__ import annotations

from datetime import UTC, date, datetime
from typing import Any

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Column,
    Date,
    DateTime,
    Engine,
    Float,
    ForeignKey,
    Index,
    Integer,
    MetaData,
    Table,
    Text,
    create_engine,
    event,
    text,
)

metadata = MetaData()

TS = DateTime(timezone=True)

day = Table(
    "day",
    metadata,
    Column("date", Date, primary_key=True),
    Column("planned_at", TS),
    Column("first_open_at", TS),
    Column("created_at", TS, nullable=False),
    Column("updated_at", TS, nullable=False),
)

subject = Table(
    "subject",
    metadata,
    Column("name", Text, primary_key=True),
    Column("last_used", Date),
    Column("created_at", TS, nullable=False),
    Column("updated_at", TS, nullable=False),
)

deadline = Table(
    "deadline",
    metadata,
    Column("id", Text, primary_key=True),
    Column("title", Text, nullable=False),
    Column("subject", Text),
    Column("due_date", Date, nullable=False),
    Column("created_at", TS, nullable=False),
    Column("updated_at", TS, nullable=False),
)

task = Table(
    "task",
    metadata,
    Column("id", Text, primary_key=True),
    Column("date", Date, ForeignKey("day.date"), nullable=False, index=True),
    Column("type", Text, nullable=False),
    Column("title", Text, nullable=False),
    Column("category", Text),
    Column("status", Text, nullable=False, server_default="open"),
    Column("completed_at", TS),
    Column("time_spent_minutes", Integer, nullable=False, server_default="0"),
    Column("planned_the_night_before", Boolean, nullable=False, server_default=text("false")),
    Column("created_at", TS, nullable=False),
    Column("updated_at", TS, nullable=False),
    CheckConstraint("type IN ('mit', 'secondary')", name="task_type"),
    CheckConstraint("status IN ('open', 'done')", name="task_status"),
)
Index(
    "one_mit_per_day",
    task.c.date,
    unique=True,
    sqlite_where=task.c.type == "mit",
    postgresql_where=task.c.type == "mit",
)

study_item = Table(
    "study_item",
    metadata,
    Column("id", Text, primary_key=True),
    Column("date", Date, ForeignKey("day.date"), nullable=False, index=True),
    Column("subject", Text, nullable=False),
    Column("work_to_do", Text, nullable=False),
    Column("work_completed", Text, nullable=False, server_default="not_started"),
    Column("time_spent_minutes", Integer, nullable=False, server_default="0"),
    Column("planned_the_night_before", Boolean, nullable=False, server_default=text("false")),
    Column("created_at", TS, nullable=False),
    Column("updated_at", TS, nullable=False),
    CheckConstraint("work_completed IN ('not_started', 'partial', 'done')", name="study_status"),
)

time_session = Table(
    "time_session",
    metadata,
    Column("id", Text, primary_key=True),
    Column("task_id", Text, ForeignKey("task.id", ondelete="CASCADE"), index=True),
    Column("study_item_id", Text, ForeignKey("study_item.id", ondelete="CASCADE"), index=True),
    Column("started_at", TS, nullable=False),
    Column("ended_at", TS),
    Column("minutes", Integer),
    Column("updated_at", TS, nullable=False),
    CheckConstraint(
        "(task_id IS NOT NULL AND study_item_id IS NULL) OR (task_id IS NULL AND study_item_id IS NOT NULL)",
        name="session_owner",
    ),
)

# Server-only: every forecast shown on the phone, kept so live calibration can
# be scored once the day's outcome is known.
prediction_log = Table(
    "prediction_log",
    metadata,
    Column("date", Date, primary_key=True),
    Column("p_mit_done", Float, nullable=False),
    Column("model", Text, nullable=False),
    Column("predicted_at", TS, nullable=False),
)

# Order matters: parents before children (inserts), children before parents (deletes).
SYNCED: dict[str, Table] = {
    "day": day,
    "subject": subject,
    "deadline": deadline,
    "task": task,
    "study_item": study_item,
    "time_session": time_session,
}


def key_column(table: Table) -> Column:
    (pk,) = table.primary_key.columns
    return pk


def make_engine(url: str) -> Engine:
    engine = create_engine(url, future=True)
    if engine.dialect.name == "sqlite":

        @event.listens_for(engine, "connect")
        def _fk_on(dbapi_conn, _):  # pragma: no cover - trivial
            dbapi_conn.execute("PRAGMA foreign_keys = ON")

    return engine


def create_all(engine: Engine) -> None:
    metadata.create_all(engine)


# ----------------------------------------------------------------- wire format


def _parse_ts(v: str) -> datetime:
    dt = datetime.fromisoformat(v.replace("Z", "+00:00"))
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def to_db(table: Table, row: dict[str, Any]) -> dict[str, Any]:
    """Phone JSON row -> typed values. Unknown columns are dropped."""
    out: dict[str, Any] = {}
    for col in table.columns:
        if col.name not in row:
            continue
        v = row[col.name]
        if v is not None:
            if isinstance(col.type, DateTime):
                v = _parse_ts(v)
            elif isinstance(col.type, Date):
                v = date.fromisoformat(v)
            elif isinstance(col.type, Boolean):
                v = bool(v)
        out[col.name] = v
    return out


def format_ts(dt: datetime) -> str:
    if dt.tzinfo is None:  # SQLite drops tzinfo; values are always stored as UTC
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def to_wire(table: Table, row: dict[str, Any]) -> dict[str, Any]:
    """Typed row -> the phone's encoding (text dates, 0/1 booleans)."""
    out: dict[str, Any] = {}
    for col in table.columns:
        v = row[col.name]
        if v is not None:
            if isinstance(col.type, DateTime):
                v = format_ts(v)
            elif isinstance(col.type, Date):
                v = v.isoformat()
            elif isinstance(col.type, Boolean):
                v = 1 if v else 0
        out[col.name] = v
    return out
