from datetime import date

import pytest
from fastapi.testclient import TestClient

from telos.db import make_engine
from telos.ml.data import load_tables
from telos.ml.simulate import simulate
from telos.ml.train import save, train
from telos.server.app import Settings, create_app

TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
TS = "2026-09-29T20:00:00.000000Z"
LATER = "2026-09-30T08:00:00.000000Z"


def _task(id_, type_="mit", title="Write intro", updated=TS, date_="2026-09-30"):
    return {
        "id": id_,
        "date": date_,
        "type": type_,
        "title": title,
        "category": "project",
        "status": "open",
        "completed_at": None,
        "time_spent_minutes": 0,
        "planned_the_night_before": 1,
        "goal_id": None,
        "step_id": None,
        "created_at": TS,
        "updated_at": updated,
    }


@pytest.fixture
def client(tmp_path):
    settings = Settings(database_url=f"sqlite:///{tmp_path / 't.db'}", token=TOKEN, model_path=tmp_path / "m.joblib")
    return TestClient(create_app(settings)), settings


def test_rejects_bad_token(client):
    c, _ = client
    assert c.get("/health").status_code == 401
    assert c.get("/health", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert c.get("/health", headers=AUTH).status_code == 200


def test_push_then_pull_round_trips_phone_format(client):
    c, _ = client
    day = {"date": "2026-09-30", "planned_at": TS, "first_open_at": None, "created_at": TS, "updated_at": TS}
    body = {"rows": {"day": [day], "task": [_task("a")]}, "deletes": []}
    r = c.post("/sync/push", json=body, headers=AUTH)
    assert r.json()["inserted"] == 2

    rows = c.get("/sync/pull", headers=AUTH).json()["rows"]
    assert rows["day"] == [day]
    assert rows["task"] == [_task("a")]  # booleans back to 0/1, dates back to text


def test_last_write_wins(client):
    c, _ = client
    day = {"date": "2026-09-30", "planned_at": TS, "first_open_at": None, "created_at": TS, "updated_at": TS}
    c.post("/sync/push", json={"rows": {"day": [day], "task": [_task("a", title="new", updated=LATER)]}}, headers=AUTH)
    r = c.post("/sync/push", json={"rows": {"task": [_task("a", title="stale", updated=TS)]}}, headers=AUTH)
    assert r.json()["skipped"] == 1
    assert c.get("/sync/pull", headers=AUTH).json()["rows"]["task"][0]["title"] == "new"


def test_replacing_the_mit_applies_delete_before_insert(client):
    c, _ = client
    day = {"date": "2026-09-30", "planned_at": TS, "first_open_at": None, "created_at": TS, "updated_at": TS}
    c.post("/sync/push", json={"rows": {"day": [day], "task": [_task("old")]}}, headers=AUTH)
    # Phone deleted the old MIT and created a new one for the same day.
    body = {
        "rows": {"task": [_task("new", updated=LATER)]},
        "deletes": [{"entity": "task", "key": "old", "deleted_at": LATER}],
    }
    r = c.post("/sync/push", json=body, headers=AUTH)
    assert r.status_code == 200, r.text
    assert [t["id"] for t in c.get("/sync/pull", headers=AUTH).json()["rows"]["task"]] == ["new"]


def test_prediction_endpoint_uses_trained_model(client):
    c, settings = client
    engine = make_engine(settings.database_url)
    simulate(engine, days=200, end=date(2026, 9, 29))
    with engine.connect() as conn:
        tables = load_tables(conn)
    assert c.get("/predictions/2026-09-29", headers=AUTH).status_code == 404  # no model yet
    save(train(tables), settings.model_path)

    mit_day = tables.task[tables.task["type"] == "mit"]["date"].max().date()
    r = c.get(f"/predictions/{mit_day}", headers=AUTH)
    assert r.status_code == 200, r.text
    body = r.json()
    assert 0 < body["p_mit_done"] < 1
    assert body["first_forecast"] == body["p_mit_done"]
    assert c.get("/predictions/2030-01-01", headers=AUTH).status_code == 404  # nothing planned


def test_weekly_goals_round_trip_and_cascade(client):
    c, _ = client
    goal = {
        "id": "g1",
        "week_start": "2026-11-08",
        "title": "Lab report",
        "kind": "task",
        "priority": "high",
        "status": "open",
        "rating": None,
        "created_at": TS,
        "updated_at": TS,
    }
    step = {
        "id": "s1",
        "goal_id": "g1",
        "position": 0,
        "title": "Method",
        "status": "done",
        "created_at": TS,
        "updated_at": TS,
    }
    review = {"week_start": "2026-11-08", "score": 4, "reviewed_at": TS, "created_at": TS, "updated_at": TS}
    day = {"date": "2026-11-09", "planned_at": TS, "first_open_at": None, "created_at": TS, "updated_at": TS}
    picked = {**_task("t1", date_="2026-11-09"), "goal_id": "g1", "step_id": "s1"}
    body = {"rows": {"day": [day], "goal": [goal], "goal_step": [step], "week_review": [review], "task": [picked]}}
    assert c.post("/sync/push", json=body, headers=AUTH).json()["inserted"] == 5

    rows = c.get("/sync/pull", headers=AUTH).json()["rows"]
    assert rows["goal"] == [goal]
    assert rows["goal_step"] == [step]
    assert rows["week_review"] == [review]
    assert rows["task"] == [picked]

    # Deleting the goal on the phone removes its steps; the task stays.
    c.post("/sync/push", json={"deletes": [{"entity": "goal", "key": "g1", "deleted_at": LATER}]}, headers=AUTH)
    rows = c.get("/sync/pull", headers=AUTH).json()["rows"]
    assert rows["goal"] == [] and rows["goal_step"] == []
    assert [t["id"] for t in rows["task"]] == ["t1"]


def test_existing_database_gets_new_task_columns(tmp_path):
    from sqlalchemy import inspect, text

    from telos.db import create_all

    engine = make_engine(f"sqlite:///{tmp_path / 'old.db'}")
    with engine.begin() as conn:  # a task table from before weekly goals
        conn.execute(text("CREATE TABLE task (id TEXT PRIMARY KEY, date DATE, title TEXT)"))
    create_all(engine)
    create_all(engine)  # idempotent
    cols = {c["name"] for c in inspect(engine).get_columns("task")}
    assert {"goal_id", "step_id"} <= cols
