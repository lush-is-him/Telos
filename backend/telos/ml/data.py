"""Load the synced tables into pandas with local-time helpers."""

from __future__ import annotations

from dataclasses import dataclass

import pandas as pd
from sqlalchemy import Connection, select

from telos.db import SYNCED


@dataclass
class Tables:
    day: pd.DataFrame
    task: pd.DataFrame
    study_item: pd.DataFrame
    time_session: pd.DataFrame
    deadline: pd.DataFrame
    tz: str = "UTC"


_TS_COLS = {
    "day": ["planned_at", "first_open_at", "created_at", "updated_at"],
    "task": ["completed_at", "created_at", "updated_at"],
    "study_item": ["created_at", "updated_at"],
    "time_session": ["started_at", "ended_at", "updated_at"],
    "deadline": ["created_at", "updated_at"],
}
_DATE_COLS = {"day": ["date"], "task": ["date"], "study_item": ["date"], "deadline": ["due_date"]}


def load_tables(conn: Connection, tz: str = "UTC") -> Tables:
    frames: dict[str, pd.DataFrame] = {}
    for name in _TS_COLS:
        table = SYNCED[name]
        cols = [str(c.name) for c in table.columns]
        df = pd.DataFrame([tuple(r) for r in conn.execute(select(table))], columns=cols)
        for c in _TS_COLS[name]:
            # SQLite hands back naive datetimes; values are stored as UTC.
            df[c] = pd.to_datetime(df[c], utc=True).dt.tz_convert(tz)
        for c in _DATE_COLS.get(name, []):
            df[c] = pd.to_datetime(df[c]).dt.normalize()
        frames[name] = df
    return Tables(tz=tz, **frames)
