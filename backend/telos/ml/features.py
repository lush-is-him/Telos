"""Feature tables.

`daily_features`: one row per day that had an MIT. Every feature is either
(a) part of the plan, known when the plan is saved, or (b) history strictly
before that day. Nothing from the day itself (completion time, minutes logged,
app opens) is used, so the forecast can be shown the night before.

`task_duration_features`: one row per completed task with logged time, for the
time-to-complete regression. Same rule: only prior history.
"""

from __future__ import annotations

import re

import numpy as np
import pandas as pd

from telos.ml.data import Tables

CATEGORIES = ["project", "study", "admin", "other"]

NUMERIC = [
    "planned_night_before",
    "is_weekend",
    "n_secondary",
    "n_study",
    "load",
    "mit_title_words",
    "mit_specific",
    "deadline_within_2d",
    "days_to_deadline",
    "yesterday_mit_done",
    "mit_rate_7",
    "mit_rate_28",
    "streak",
    "plan_nb_rate_7",
    "study_done_rate_7",
    "minutes_per_day_7",
]
CATEGORICAL = ["mit_category", "weekday"]
FEATURES = NUMERIC + CATEGORICAL
TARGET = "y"

_DIGIT = re.compile(r"\d")


def title_words(title: str) -> int:
    return len(str(title).split())


def is_specific(title: str) -> int:
    """Cheap proxy for a concrete task: mentions a number or is 5+ words."""
    t = str(title)
    return int(bool(_DIGIT.search(t)) or title_words(t) >= 5)


def _calendar(t: Tables, until: pd.Timestamp | None = None) -> pd.DataFrame:
    """Per-calendar-day history signals, one row per date, no gaps."""
    dates = pd.concat([t.task["date"], t.study_item["date"], t.day["date"]])
    if dates.empty:
        return pd.DataFrame()
    end = max(dates.max(), until) if until is not None else dates.max()
    idx = pd.date_range(dates.min(), end, freq="D")

    mit = t.task[t.task["type"] == "mit"].set_index("date")
    cal = pd.DataFrame(index=idx)
    cal["mit_done"] = (mit["status"] == "done").astype(float).reindex(idx).fillna(0.0)
    cal["plan_nb"] = mit["planned_the_night_before"].astype(float).reindex(idx).fillna(0.0)

    study = t.study_item.groupby("date")["work_completed"].agg(lambda s: (s == "done").mean())
    cal["study_done"] = study.reindex(idx)

    minutes = pd.concat(
        [t.task.groupby("date")["time_spent_minutes"].sum(), t.study_item.groupby("date")["time_spent_minutes"].sum()],
        axis=1,
    ).sum(axis=1)
    cal["minutes"] = minutes.reindex(idx).fillna(0.0)

    # Everything below is shifted by one day: only strictly-past information.
    prev = cal.shift(1)
    out = pd.DataFrame(index=idx)
    out["yesterday_mit_done"] = prev["mit_done"].fillna(0.0)
    out["mit_rate_7"] = prev["mit_done"].rolling(7, min_periods=1).mean().fillna(0.0)
    out["mit_rate_28"] = prev["mit_done"].rolling(28, min_periods=1).mean().fillna(0.0)
    out["plan_nb_rate_7"] = prev["plan_nb"].rolling(7, min_periods=1).mean().fillna(0.0)
    out["study_done_rate_7"] = prev["study_done"].rolling(7, min_periods=1).mean()
    out["minutes_per_day_7"] = prev["minutes"].rolling(7, min_periods=1).mean().fillna(0.0)

    # Streak of consecutive MIT-done days ending yesterday.
    done = cal["mit_done"].to_numpy()
    streak = np.zeros(len(done))
    run = 0
    for i in range(len(done)):
        streak[i] = run
        run = run + 1 if done[i] == 1 else 0
    out["streak"] = streak
    return out


def _days_to_deadline(dates: pd.Series, deadlines: pd.DataFrame) -> pd.Series:
    if deadlines.empty:
        return pd.Series(np.nan, index=dates.index)
    due = np.sort(deadlines["due_date"].to_numpy())
    pos = np.searchsorted(due, dates.to_numpy(), side="left")
    out = np.full(len(dates), np.nan)
    ok = pos < len(due)
    out[ok] = (due[pos[ok]] - dates.to_numpy()[ok]) / np.timedelta64(1, "D")
    return pd.Series(out, index=dates.index)


def daily_features(t: Tables, until: pd.Timestamp | None = None) -> pd.DataFrame:
    """One row per day with an MIT. `until` extends the calendar so a plan
    for tomorrow still gets history features."""
    mit = t.task[t.task["type"] == "mit"].copy()
    if mit.empty:
        return pd.DataFrame(columns=["date", *FEATURES, TARGET])

    secondaries = t.task[t.task["type"] == "secondary"].groupby("date").size()
    study = t.study_item.groupby("date").size()

    df = pd.DataFrame({"date": mit["date"].to_numpy()})
    df["planned_night_before"] = mit["planned_the_night_before"].astype(int).to_numpy()
    df["weekday"] = df["date"].dt.dayofweek.astype(str)
    df["is_weekend"] = (df["date"].dt.dayofweek >= 5).astype(int)
    df["n_secondary"] = secondaries.reindex(df["date"]).fillna(0).to_numpy()
    df["n_study"] = study.reindex(df["date"]).fillna(0).to_numpy()
    df["load"] = df["n_secondary"] + df["n_study"]
    df["mit_category"] = mit["category"].fillna("other").to_numpy()
    df["mit_title_words"] = mit["title"].map(title_words).to_numpy()
    df["mit_specific"] = mit["title"].map(is_specific).to_numpy()

    dtd = _days_to_deadline(df["date"], t.deadline)
    df["deadline_within_2d"] = (dtd <= 2).astype(int)
    df["days_to_deadline"] = dtd.clip(upper=30).fillna(30)

    cal = _calendar(t, until)
    df = df.join(cal, on="date")
    df[TARGET] = (mit["status"] == "done").astype(int).to_numpy()
    return df.sort_values("date").reset_index(drop=True)


DURATION_NUMERIC = [
    "title_words",
    "specific",
    "is_weekend",
    "is_mit",
    "planned_night_before",
    "prior_cat_median",
    "prior_cat_count",
]
DURATION_CATEGORICAL = ["category"]


def task_duration_features(t: Tables) -> pd.DataFrame:
    """Completed tasks with logged time. Target: log(minutes)."""
    df = t.task[(t.task["status"] == "done") & (t.task["time_spent_minutes"] > 0)].copy()
    df = df.sort_values(["date", "created_at"]).reset_index(drop=True)
    df["category"] = df["category"].fillna("other")
    df["title_words"] = df["title"].map(title_words)
    df["specific"] = df["title"].map(is_specific)
    df["is_weekend"] = (df["date"].dt.dayofweek >= 5).astype(int)
    df["is_mit"] = (df["type"] == "mit").astype(int)
    df["planned_night_before"] = df["planned_the_night_before"].astype(int)
    df["log_minutes"] = np.log(df["time_spent_minutes"])

    # Prior median per category using only earlier *days* (same-day tasks excluded).
    medians, counts = [], []
    for _, row in df.iterrows():
        past = df[(df["category"] == row["category"]) & (df["date"] < row["date"])]["time_spent_minutes"]
        medians.append(past.median() if len(past) else np.nan)
        counts.append(len(past))
    df["prior_cat_median"] = pd.Series(medians, dtype=float).fillna(30.0)
    df["prior_cat_count"] = counts
    return df
