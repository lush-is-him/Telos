from __future__ import annotations

from datetime import date

import pandas as pd

from telos.ml.data import Tables
from telos.ml.features import daily_features
from telos.ml.model_io import TrainedModel


def predict_day(m: TrainedModel, tables: Tables, day: date) -> float | None:
    """P(MIT done) for `day` from its plan and the history before it."""
    ts = pd.Timestamp(day)
    feats = daily_features(tables, until=ts)
    row = feats[feats["date"] == ts]
    if row.empty:
        return None
    return float(m.model.predict_proba(row)[0])
