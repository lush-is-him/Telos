from datetime import date

import numpy as np
import pandas as pd
import pytest

from telos.db import make_engine
from telos.ml.data import Tables, load_tables
from telos.ml.evaluate import block_bootstrap_diff, walk_forward
from telos.ml.features import daily_features, is_specific
from telos.ml.models import BaseRate
from telos.ml.simulate import simulate


@pytest.fixture(scope="module")
def tables() -> Tables:
    engine = make_engine("sqlite:///:memory:")
    simulate(engine, days=150, end=date(2026, 9, 29), seed=3)
    with engine.connect() as conn:
        return load_tables(conn)


def _mini(outcomes: list[str | None]) -> Tables:
    """A hand-built history: one MIT per day, None = no plan that day."""
    start = pd.Timestamp("2026-09-01")
    rows = []
    for i, o in enumerate(outcomes):
        if o is None:
            continue
        rows.append(
            {
                "id": str(i),
                "date": start + pd.Timedelta(days=i),
                "type": "mit",
                "title": "Write 3 pages",
                "category": "project",
                "status": o,
                "time_spent_minutes": 10,
                "planned_the_night_before": True,
            }
        )
    task = pd.DataFrame(rows)
    empty_study = pd.DataFrame(columns=["date", "work_completed", "time_spent_minutes"])
    return Tables(
        day=pd.DataFrame(columns=["date"]),
        task=task,
        study_item=empty_study,
        time_session=pd.DataFrame(),
        deadline=pd.DataFrame(columns=["due_date"]),
    )


def test_history_features_by_hand():
    f = daily_features(_mini(["done", "done", None, "done", "done", "open"])).set_index("date")
    d = lambda i: pd.Timestamp("2026-09-01") + pd.Timedelta(days=i)  # noqa: E731
    assert f.loc[d(0), "streak"] == 0 and f.loc[d(0), "yesterday_mit_done"] == 0
    assert f.loc[d(1), "streak"] == 1 and f.loc[d(1), "yesterday_mit_done"] == 1
    assert f.loc[d(3), "streak"] == 0  # the unplanned day broke it
    assert f.loc[d(5), "streak"] == 2
    assert f.loc[d(5), "mit_rate_7"] == pytest.approx(4 / 5)
    assert list(f["y"]) == [1, 1, 1, 1, 0]


def test_no_leakage_from_the_future(tables):
    """Rewriting every outcome after a cutoff must not change features up to it."""
    before = daily_features(tables)
    cutoff = before["date"].iloc[len(before) // 2]

    mutated = Tables(**{**tables.__dict__})
    mutated.task = tables.task.copy()
    future = mutated.task["date"] >= cutoff
    mutated.task.loc[future, "status"] = np.where(mutated.task.loc[future, "status"] == "done", "open", "done")
    mutated.task.loc[future, "time_spent_minutes"] = 999
    after = daily_features(mutated)

    cols = [c for c in before.columns if c != "y"]
    pd.testing.assert_frame_equal(before.loc[before["date"] <= cutoff, cols], after.loc[after["date"] <= cutoff, cols])


def test_walk_forward_never_trains_on_test_days(tables):
    feats = daily_features(tables)
    seen = []

    class Spy(BaseRate):
        def fit(self, df):
            self.max_train = df["date"].max()
            return super().fit(df)

        def predict_proba(self, df):
            seen.append((self.max_train, df["date"].min()))
            return super().predict_proba(df)

    oof = walk_forward(feats, Spy, min_train_days=30, step_days=7)
    assert len(oof) > 0
    assert all(train_end < test_start for train_end, test_start in seen)


def test_specificity_heuristic():
    assert is_specific("Write 500 words of section 2")
    assert is_specific("Draft the methods section for supervisor")
    assert not is_specific("Study")


def test_block_bootstrap_detects_a_clear_winner():
    rng = np.random.default_rng(0)
    y = rng.integers(0, 2, 300).astype(float)
    good = np.clip(y * 0.7 + 0.15, 0, 1)
    bad = np.full(300, 0.5)
    point, lo, hi = block_bootstrap_diff(y, good, bad)
    assert point < 0 and hi < 0
