"""Weekly training job: evaluate every candidate with walk-forward CV, pick the
best by Brier score, refit it on all data and save it for the API."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import pandas as pd

from telos.ml.data import Tables
from telos.ml.evaluate import (
    block_bootstrap_diff,
    classification_metrics,
    regression_metrics,
    walk_forward,
)
from telos.ml.features import daily_features, task_duration_features
from telos.ml.model_io import TrainedModel, save_model
from telos.ml.models import candidates, duration_candidates

# Below this, report descriptive stats only — a model on 30 days is noise.
MIN_MIT_DAYS = 60


@dataclass
class TrainResult:
    features: pd.DataFrame
    oof: dict[str, pd.DataFrame]
    metrics: pd.DataFrame
    best: str
    vs_baseline: tuple[float, float, float] | None
    final: TrainedModel | None
    duration_metrics: pd.DataFrame | None
    duration_oof: dict[str, pd.DataFrame]


def train(tables: Tables, min_train_days: int = 60, step_days: int = 14) -> TrainResult:
    feats = daily_features(tables)
    if len(feats) < MIN_MIT_DAYS:
        return TrainResult(feats, {}, pd.DataFrame(), "", None, None, None, {})

    oof, rows = {}, []
    factories = {f().name: f for f in candidates()}
    for name, factory in factories.items():
        oof[name] = walk_forward(feats, factory, min_train_days, step_days)
        rows.append({"model": name, **classification_metrics(oof[name])})
    metrics = pd.DataFrame(rows).sort_values("brier").reset_index(drop=True)

    best = metrics.loc[~metrics["model"].str.startswith("baseline"), "model"].iloc[0]
    best_baseline = metrics.loc[metrics["model"].str.startswith("baseline"), "model"].iloc[0]
    a, b = oof[best], oof[best_baseline]
    vs = block_bootstrap_diff(a["y"].to_numpy(float), a["p"].to_numpy(float), b["p"].to_numpy(float))

    # Only ship the model if it actually beats the best baseline; otherwise ship the baseline.
    ship = best if vs[0] < 0 else best_baseline
    final_model = factories[ship]().fit(feats)
    final = TrainedModel(
        name=ship,
        model=final_model,
        n_training_days=len(feats),
        trained_at=datetime.now(UTC).isoformat(timespec="seconds"),
        cv_metrics={r["model"]: {k: v for k, v in r.items() if k != "model"} for r in rows},
    )

    dur = task_duration_features(tables)
    duration_oof, drows = {}, []
    if len(dur) >= MIN_MIT_DAYS:
        for factory in duration_candidates():
            name = factory().name
            duration_oof[name] = walk_forward(
                dur, factory, min_train_days, step_days, predict="predict", target="log_minutes"
            )
            drows.append({"model": name, **regression_metrics(duration_oof[name])})
    duration_metrics = pd.DataFrame(drows).sort_values("mae_minutes").reset_index(drop=True) if drows else None

    return TrainResult(feats, oof, metrics, best, vs, final, duration_metrics, duration_oof)


def save(result: TrainResult, model_path: Path) -> None:
    if result.final is None:
        return
    save_model(result.final, model_path)
    summary = {
        "shipped": result.final.name,
        "best_non_baseline": result.best,
        "brier_diff_vs_best_baseline": result.vs_baseline,
        "n_training_days": result.final.n_training_days,
        "trained_at": result.final.trained_at,
        "cv": result.final.cv_metrics,
    }
    model_path.with_suffix(".json").write_text(json.dumps(summary, indent=2))
