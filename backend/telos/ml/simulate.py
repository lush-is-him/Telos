"""Synthetic Telos user.

Generates a year of plausible history straight into the real schema so the
whole pipeline (features -> models -> report -> API) runs before there is a
year of real data. The behavioural effects below are *planted*: the report
checks whether the model recovers them, which is a sanity check on the
feature pipeline, not evidence about real behaviour.

Everything is seeded and deterministic.
"""

from __future__ import annotations

import math
import random
import uuid
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import Engine, insert

from telos.db import create_all, day, deadline, study_item, subject, task, time_session

# Planted log-odds effects on "MIT gets done". Reported alongside the fitted model.
TRUE_EFFECTS: dict[str, float] = {
    "intercept": -0.9,
    "planned_night_before": 0.9,
    "yesterday_mit_done": 0.6,
    "is_weekend": -0.7,
    "load_above_2": -0.25,  # per item beyond 2 (secondaries + study items)
    "specific_title": 0.5,
    "deadline_within_2d": 0.8,
    "category_admin": 0.4,
    "category_project": -0.2,
    "category_other": 0.2,
    "momentum_7d": 0.6,  # (7-day MIT rate - 0.5) * 2 scaled
    "semester_cycle_amp": 0.4,  # unobserved: the model can't see this
}

SUBJECTS = ["Statistics", "Machine Learning", "Databases", "Linear Algebra"]
DISLIKED_SUBJECT = "Statistics"  # planted neglect

_SPECIFIC = {
    "project": ["Write 500 words of section {n}", "Fix bug #{n} in the parser", "Draft slides {n}-{m} for demo"],
    "study": ["Finish problem set {n} questions 1-{m}", "Summarise lecture {n} into flashcards"],
    "admin": ["Pay rent and file receipt {n}", "Email {n} replies from inbox"],
    "other": ["Run {n}km before 9am", "Cook meals for {n} days"],
}
_VAGUE = {
    "project": ["Work on thesis", "Project stuff", "Keep going on the app"],
    "study": ["Study", "Revise", "Catch up on lectures"],
    "admin": ["Admin", "Sort out emails"],
    "other": ["Exercise", "Errands"],
}
_SECONDARY = ["Laundry", "Call home", "Reply to messages", "Tidy desk", "Groceries", "Read 20 pages", "Gym"]
_WORK = ["Chapter {n} exercises", "Past paper {n}", "Lecture {n} notes", "Worksheet {n}", "Read section {n}.{m}"]


def _sigmoid(z: float) -> float:
    return 1 / (1 + math.exp(-z))


@dataclass
class _State:
    history: list[bool] = field(default_factory=list)  # MIT done per calendar day (False if no plan)
    break_days_left: int = 0


class Simulator:
    def __init__(self, seed: int = 7, tz: str = "UTC"):
        self.rng = random.Random(seed)
        self.tz = ZoneInfo(tz)
        self.rows: dict[str, list[dict]] = {
            k: [] for k in ["day", "subject", "deadline", "task", "study_item", "time_session"]
        }
        self._deadlines: list[tuple[date, str]] = []

    # ------------------------------------------------------------- helpers

    def _id(self) -> str:
        return str(uuid.UUID(int=self.rng.getrandbits(128), version=4))

    def _at(self, d: date, hour: float) -> datetime:
        hour = min(max(hour, 0.0), 23.99)
        h, m = int(hour), int((hour % 1) * 60)
        return datetime.combine(d, time(h, m), self.tz).astimezone(UTC)

    def _title(self, category: str, specific: bool) -> str:
        pool = (_SPECIFIC if specific else _VAGUE)[category]
        n = self.rng.randint(2, 9)
        return self.rng.choice(pool).format(n=n, m=n + self.rng.randint(1, 4))

    def _minutes(self, median: float, sigma: float = 0.5) -> int:
        return max(1, int(round(median * math.exp(self.rng.gauss(0, sigma)))))

    def _sessions(self, d: date, total: int, weekend: bool, owner: dict[str, str], completed: bool) -> datetime | None:
        """Split `total` minutes into 1-3 sessions at chronotype-shaped hours."""
        if total <= 0:
            return None
        k = min(self.rng.choice([1, 1, 2, 2, 3]), max(1, total // 15))
        parts = [total // k] * k
        parts[-1] += total - sum(parts)
        end = None
        hour = self.rng.gauss(11.5 if weekend else 9.5, 1.2) if self.rng.random() < 0.6 else self.rng.gauss(19.5, 1.5)
        for mins in parts:
            start = self._at(d, hour)
            end = start + timedelta(minutes=mins)
            self.rows["time_session"].append(
                {"id": self._id(), **owner, "started_at": start, "ended_at": end, "minutes": mins, "updated_at": end}
            )
            hour += mins / 60 + self.rng.uniform(0.5, 3)
        return end if completed else None

    def _days_to_deadline(self, d: date) -> int | None:
        future = [(due - d).days for due, _ in self._deadlines if due >= d]
        return min(future) if future else None

    # ------------------------------------------------------------- simulation

    def run(self, start: date, days: int) -> dict[str, list[dict]]:
        created = self._at(start - timedelta(days=1), 12)
        for s in SUBJECTS:
            self.rows["subject"].append({"name": s, "last_used": None, "created_at": created, "updated_at": created})

        # Coursework deadlines roughly every three weeks per subject.
        for s in SUBJECTS:
            due = start + timedelta(days=self.rng.randint(5, 20))
            while due < start + timedelta(days=days + 30):
                self._deadlines.append((due, s))
                self.rows["deadline"].append(
                    {
                        "id": self._id(),
                        "title": f"{s} coursework",
                        "subject": s,
                        "due_date": due,
                        "created_at": created,
                        "updated_at": created,
                    }
                )
                due += timedelta(days=self.rng.randint(16, 28))

        st = _State()
        for i in range(days):
            self._simulate_day(start + timedelta(days=i), i, st)
        return self.rows

    def _simulate_day(self, d: date, i: int, st: _State) -> None:
        rng, T = self.rng, TRUE_EFFECTS
        weekend = d.weekday() >= 5
        yesterday = st.history[-1] if st.history else False
        rate7 = sum(st.history[-7:]) / 7 if st.history else 0.0

        # Occasional breaks (travel, illness): nothing logged at all.
        if st.break_days_left == 0 and rng.random() < 0.012:
            st.break_days_left = rng.randint(3, 7)
        if st.break_days_left > 0:
            st.break_days_left -= 1
            st.history.append(False)
            return

        # --- planning behaviour (evening before, morning of, or not at all)
        eve_weekday = (d - timedelta(days=1)).weekday()
        p_nb = _sigmoid(0.9 + 0.8 * yesterday + 1.2 * (rate7 - 0.5) - 1.0 * (eve_weekday in (4, 5)))
        if rng.random() < p_nb:
            planned_nb, plan_time = True, self._at(d - timedelta(days=1), rng.gauss(21.3, 0.8))
        elif rng.random() < 0.55:
            planned_nb, plan_time = False, self._at(d, rng.gauss(8.3 if not weekend else 10.0, 1.0))
        else:
            st.history.append(False)
            if rng.random() < 0.5:  # opened the app but didn't plan
                t = self._at(d, rng.gauss(10, 2))
                self.rows["day"].append(
                    {"date": d, "planned_at": None, "first_open_at": t, "created_at": t, "updated_at": t}
                )
            return

        first_open = max(plan_time, self._at(d, rng.gauss(8.0 if not weekend else 10.0, 1.0)))
        self.rows["day"].append(
            {
                "date": d,
                "planned_at": plan_time,
                "first_open_at": first_open,
                "created_at": plan_time,
                "updated_at": plan_time,
            }
        )

        category = rng.choices(["project", "study", "admin", "other"], weights=[0.4, 0.35, 0.15, 0.1])[0]
        specific = rng.random() < 0.55
        n_sec = rng.choices([0, 1, 2], weights=[0.2, 0.35, 0.45])[0]
        n_study = rng.choices([0, 1, 2, 3], weights=[0.3, 0.35, 0.25, 0.1])[0]
        dtd = self._days_to_deadline(d)
        deadline_soon = dtd is not None and dtd <= 2 and category in ("study", "project")

        z = (
            T["intercept"]
            + T["planned_night_before"] * planned_nb
            + T["yesterday_mit_done"] * yesterday
            + T["is_weekend"] * weekend
            + T["load_above_2"] * max(0, n_sec + n_study - 2)
            + T["specific_title"] * specific
            + T["deadline_within_2d"] * deadline_soon
            + T.get(f"category_{category}", 0.0)
            + T["momentum_7d"] * (rate7 - 0.5) * 2
            + T["semester_cycle_amp"] * math.sin(2 * math.pi * i / 120)
        )
        mit_done = rng.random() < _sigmoid(z)
        st.history.append(mit_done)

        # --- MIT row + time
        base = {"project": 90, "study": 70, "admin": 25, "other": 40}[category] * (0.85 if specific else 1.0)
        if mit_done:
            minutes = self._minutes(base)
        else:
            minutes = 0 if rng.random() < 0.4 else int(self._minutes(base) * rng.uniform(0.1, 0.6))
        mit_id = self._id()
        end = self._sessions(d, minutes, weekend, {"task_id": mit_id, "study_item_id": None}, mit_done)
        completed_at = (end or self._at(d, rng.gauss(17, 2))) if mit_done else None
        self.rows["task"].append(
            {
                "id": mit_id,
                "date": d,
                "type": "mit",
                "title": self._title(category, specific),
                "category": category,
                "status": "done" if mit_done else "open",
                "completed_at": completed_at,
                "time_spent_minutes": minutes,
                "planned_the_night_before": planned_nb,
                "created_at": plan_time,
                "updated_at": completed_at or plan_time,
            }
        )

        # --- secondaries
        for title in rng.sample(_SECONDARY, n_sec):
            done = rng.random() < _sigmoid(0.3 + 0.8 * mit_done - 0.3 * weekend)
            mins = self._minutes(30) if done else 0
            tid = self._id()
            end = self._sessions(d, mins, weekend, {"task_id": tid, "study_item_id": None}, done)
            self.rows["task"].append(
                {
                    "id": tid,
                    "date": d,
                    "type": "secondary",
                    "title": title,
                    "category": "other",
                    "status": "done" if done else "open",
                    "completed_at": end if done else None,
                    "time_spent_minutes": mins,
                    "planned_the_night_before": planned_nb,
                    "created_at": plan_time,
                    "updated_at": end or plan_time,
                }
            )

        # --- study items
        for subj in rng.sample(SUBJECTS, n_study):
            soon = any(0 <= (due - d).days <= 3 and s == subj for due, s in self._deadlines)
            p_done = _sigmoid(0.2 + 0.7 * mit_done - 1.5 * (subj == DISLIKED_SUBJECT) + 0.6 * soon)
            r = rng.random()
            status = "done" if r < p_done else ("partial" if r < p_done + (1 - p_done) * 0.35 else "not_started")
            mins = {"done": self._minutes(45), "partial": self._minutes(20), "not_started": 0}[status]
            sid = self._id()
            end = self._sessions(d, mins, weekend, {"task_id": None, "study_item_id": sid}, status == "done")
            n = rng.randint(1, 12)
            self.rows["study_item"].append(
                {
                    "id": sid,
                    "date": d,
                    "subject": subj,
                    "work_to_do": rng.choice(_WORK).format(n=n, m=rng.randint(1, 6)),
                    "work_completed": status,
                    "time_spent_minutes": mins,
                    "planned_the_night_before": planned_nb,
                    "created_at": plan_time,
                    "updated_at": end or plan_time,
                }
            )


def write(engine: Engine, rows: dict[str, list[dict]]) -> None:
    create_all(engine)
    tables = {
        "day": day,
        "subject": subject,
        "deadline": deadline,
        "task": task,
        "study_item": study_item,
        "time_session": time_session,
    }
    with engine.begin() as conn:
        for name, table in tables.items():
            if rows[name]:
                conn.execute(insert(table), rows[name])


def simulate(
    engine: Engine, days: int = 365, seed: int = 7, tz: str = "UTC", end: date | None = None
) -> dict[str, int]:
    end = end or date.today()
    rows = Simulator(seed=seed, tz=tz).run(end - timedelta(days=days - 1), days)
    write(engine, rows)
    return {k: len(v) for k, v in rows.items()}
