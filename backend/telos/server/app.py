"""Home-server API: backup target for the phone and host for the ML model.

Run:  TELOS_TOKEN=... DATABASE_URL=postgresql+psycopg://... uvicorn --factory telos.server.app:create_app
"""

from __future__ import annotations

import os
import secrets
from datetime import UTC, date, datetime
from functools import lru_cache
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import Engine, select
from sqlalchemy.dialects import postgresql, sqlite

from telos.db import create_all, make_engine, prediction_log
from telos.server.sync import apply_push, snapshot


class Settings(BaseModel):
    database_url: str = "sqlite:///telos.db"
    token: str = ""
    model_path: Path = Path("artifacts/mit_model.joblib")
    timezone: str = "UTC"

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            database_url=os.environ.get("DATABASE_URL", cls.model_fields["database_url"].default),
            token=os.environ.get("TELOS_TOKEN", ""),
            model_path=Path(os.environ.get("TELOS_MODEL_PATH", "artifacts/mit_model.joblib")),
            timezone=os.environ.get("TELOS_TZ", "UTC"),
        )


class PushBody(BaseModel):
    rows: dict[str, list[dict[str, Any]]] = Field(default_factory=dict)
    deletes: list[dict[str, Any]] = Field(default_factory=list)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    if not settings.token:
        raise RuntimeError("Set TELOS_TOKEN — the API refuses to run without auth.")

    engine: Engine = make_engine(settings.database_url)
    create_all(engine)
    app = FastAPI(title="Telos", version="1.0")

    def auth(authorization: str = Header(default="")) -> None:
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not secrets.compare_digest(token, settings.token):
            raise HTTPException(status_code=401, detail="bad token")

    @lru_cache(maxsize=1)
    def _model(mtime: float):
        from telos.ml.model_io import load_model

        return load_model(settings.model_path)

    def current_model():
        if not settings.model_path.exists():
            return None
        return _model(settings.model_path.stat().st_mtime)

    @app.get("/health", dependencies=[Depends(auth)])
    def health() -> dict[str, Any]:
        return {"ok": True, "model": settings.model_path.exists()}

    @app.post("/sync/push", dependencies=[Depends(auth)])
    def push(body: PushBody) -> dict[str, Any]:
        with engine.begin() as conn:
            stats = apply_push(conn, body.rows, body.deletes)
        return {"ok": True, **stats}

    @app.get("/sync/pull", dependencies=[Depends(auth)])
    def pull() -> dict[str, Any]:
        with engine.connect() as conn:
            return {"rows": snapshot(conn)}

    @app.get("/predictions/{day}", dependencies=[Depends(auth)])
    def predict(day: date) -> dict[str, Any]:
        model = current_model()
        if model is None:
            raise HTTPException(status_code=404, detail="no trained model yet")

        from telos.ml.data import load_tables
        from telos.ml.predict import predict_day

        with engine.connect() as conn:
            tables = load_tables(conn, settings.timezone)
        p = predict_day(model, tables, day)
        if p is None:
            raise HTTPException(status_code=404, detail="no MIT planned for that day")

        # Keep the first forecast for each day: that's the one made at planning time.
        row = {"date": day, "p_mit_done": p, "model": model.name, "predicted_at": datetime.now(UTC)}
        dialect = postgresql if engine.dialect.name == "postgresql" else sqlite
        with engine.begin() as conn:
            conn.execute(dialect.insert(prediction_log).values(**row).on_conflict_do_nothing(index_elements=["date"]))
            logged = conn.execute(select(prediction_log.c.p_mit_done).where(prediction_log.c.date == day)).scalar_one()
        return {
            "date": day.isoformat(),
            "p_mit_done": round(p, 3),
            "first_forecast": round(logged, 3),
            "model": model.name,
            "n_training_days": model.n_training_days,
        }

    return app
