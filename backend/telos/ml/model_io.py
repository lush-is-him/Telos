from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import joblib


@dataclass
class TrainedModel:
    name: str
    model: Any  # anything with predict_proba(df)
    n_training_days: int
    trained_at: str
    cv_metrics: dict[str, dict[str, float]] = field(default_factory=dict)


def save_model(m: TrainedModel, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(m, path)


def load_model(path: Path) -> TrainedModel:
    return joblib.load(path)
