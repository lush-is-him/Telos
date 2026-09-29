"""Walk-forward evaluation. Random K-fold would let the model train on the
future, which is exactly the situation it will never be in, so every fold
trains on the past and scores the next block of days."""

from __future__ import annotations

from collections.abc import Callable

import numpy as np
import pandas as pd
from sklearn.metrics import brier_score_loss, log_loss, roc_auc_score

from telos.ml.features import TARGET


def walk_forward(
    df: pd.DataFrame,
    factory: Callable,
    min_train_days: int = 60,
    step_days: int = 14,
    predict: str = "predict_proba",
    target: str = TARGET,
) -> pd.DataFrame:
    """Out-of-fold predictions from an expanding training window."""
    dates = df["date"]
    start = dates.min() + pd.Timedelta(days=min_train_days)
    out = []
    cutoff = start
    while cutoff <= dates.max():
        train = df[dates < cutoff]
        test = df[(dates >= cutoff) & (dates < cutoff + pd.Timedelta(days=step_days))]
        cutoff += pd.Timedelta(days=step_days)
        if test.empty or (predict == "predict_proba" and train[target].nunique() < 2):
            continue
        model = factory().fit(train)
        pred = getattr(model, predict)(test)
        out.append(pd.DataFrame({"date": test["date"].to_numpy(), "y": test[target].to_numpy(), "p": pred}))
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame(columns=["date", "y", "p"])


def expected_calibration_error(y: np.ndarray, p: np.ndarray, bins: int = 10) -> float:
    edges = np.linspace(0, 1, bins + 1)
    idx = np.clip(np.digitize(p, edges) - 1, 0, bins - 1)
    ece = 0.0
    for b in range(bins):
        m = idx == b
        if m.any():
            ece += m.mean() * abs(y[m].mean() - p[m].mean())
    return float(ece)


def classification_metrics(oof: pd.DataFrame) -> dict[str, float]:
    y, p = oof["y"].to_numpy(int), np.clip(oof["p"].to_numpy(float), 1e-4, 1 - 1e-4)
    return {
        "n": int(len(y)),
        "brier": float(brier_score_loss(y, p)),
        "log_loss": float(log_loss(y, p, labels=[0, 1])),
        "auc": float(roc_auc_score(y, p)) if len(np.unique(y)) == 2 else float("nan"),
        "ece": expected_calibration_error(y, p),
    }


def calibration_table(oof: pd.DataFrame, bins: int = 5) -> pd.DataFrame:
    q = pd.qcut(oof["p"], bins, duplicates="drop")
    return (
        oof.groupby(q, observed=True)
        .agg(p_mean=("p", "mean"), y_rate=("y", "mean"), n=("y", "size"))
        .reset_index(drop=True)
    )


def block_bootstrap_diff(
    y: np.ndarray,
    p_a: np.ndarray,
    p_b: np.ndarray,
    metric: Callable[[np.ndarray, np.ndarray], float] = lambda y, p: float(np.mean((p - y) ** 2)),
    block: int = 7,
    n_boot: int = 2000,
    seed: int = 0,
) -> tuple[float, float, float]:
    """metric(a) - metric(b) with a 95% CI. Days are autocorrelated (streaks),
    so resample contiguous week-long blocks instead of single days."""
    rng = np.random.default_rng(seed)
    n = len(y)
    n_blocks = int(np.ceil(n / block))
    starts_max = max(1, n - block + 1)
    diffs = np.empty(n_boot)
    for i in range(n_boot):
        starts = rng.integers(0, starts_max, n_blocks)
        idx = (starts[:, None] + np.arange(block)).ravel()[:n]
        diffs[i] = metric(y[idx], p_a[idx]) - metric(y[idx], p_b[idx])
    point = metric(y, p_a) - metric(y, p_b)
    lo, hi = np.percentile(diffs, [2.5, 97.5])
    return float(point), float(lo), float(hi)


def regression_metrics(oof: pd.DataFrame) -> dict[str, float]:
    """oof holds log-minutes; report errors in minutes, which is what users feel."""
    actual, pred = np.exp(oof["y"].to_numpy(float)), np.exp(oof["p"].to_numpy(float))
    return {
        "n": int(len(actual)),
        "mae_minutes": float(np.mean(np.abs(actual - pred))),
        "median_ae_minutes": float(np.median(np.abs(actual - pred))),
        "within_25pct": float(np.mean(np.abs(actual - pred) <= 0.25 * actual)),
    }
