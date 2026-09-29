"""Last-write-wins sync for a single user with one phone."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from sqlalchemy import Connection, delete, insert, select, update

from telos.db import SYNCED, key_column, to_db, to_wire


def _utc(dt: datetime) -> datetime:
    return dt.replace(tzinfo=UTC) if dt.tzinfo is None else dt


def apply_push(
    conn: Connection, rows: dict[str, list[dict[str, Any]]], deletes: list[dict[str, Any]]
) -> dict[str, int]:
    """Apply one push inside the caller's transaction.

    Deletes go first: the phone may delete an MIT and create a new one in the
    same batch, and the one-MIT-per-day index must not see both.
    """
    stats = {"inserted": 0, "updated": 0, "skipped": 0, "deleted": 0}

    for d in deletes:
        table = SYNCED.get(d.get("entity", ""))
        if table is None:
            continue
        res = conn.execute(delete(table).where(key_column(table) == d["key"]))
        stats["deleted"] += res.rowcount or 0

    for name, table in SYNCED.items():  # FK order
        key = key_column(table)
        for raw in rows.get(name, []):
            row = to_db(table, raw)
            existing = conn.execute(select(table.c.updated_at).where(key == row[key.name])).scalar_one_or_none()
            if existing is None:
                conn.execute(insert(table).values(**row))
                stats["inserted"] += 1
            elif _utc(row["updated_at"]) >= _utc(existing):
                conn.execute(update(table).where(key == row[key.name]).values(**row))
                stats["updated"] += 1
            else:
                stats["skipped"] += 1
    return stats


def snapshot(conn: Connection) -> dict[str, list[dict[str, Any]]]:
    """Every synced row in the phone's wire format (for restoring a new phone)."""
    return {
        name: [to_wire(table, dict(r._mapping)) for r in conn.execute(select(table))] for name, table in SYNCED.items()
    }
