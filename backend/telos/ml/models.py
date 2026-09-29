"""Candidate models for P(MIT done). Every model — baselines included — has the
same fit / predict_proba interface over the feature DataFrame, so they are
evaluated identically."""

from __future__ import annotations

from typing import Protocol

import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingClassifier, HistGradientBoostingRegressor
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression, Ridge
from sklearn.pipeline import Pipeline, make_pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from telos.ml.features import (
    CATEGORICAL,
    DURATION_CATEGORICAL,
    DURATION_NUMERIC,
    FEATURES,
    NUMERIC,
    TARGET,
)


class Model(Protocol):
    name: str

    def fit(self, df: pd.DataFrame) -> Model: ...
    def predict_proba(self, df: pd.DataFrame) -> np.ndarray: ...


class BaseRate:
    """Predicts the training-set completion rate for every day."""

    name = "baseline_base_rate"

    def fit(self, df):
        self.p = float(df[TARGET].mean())
        return self

    def predict_proba(self, df):
        return np.full(len(df), self.p)


class Yesterday:
    """'Tomorrow looks like yesterday', calibrated: P(y | yesterday done/not)."""

    name = "baseline_yesterday"

    def fit(self, df):
        base = df[TARGET].mean()
        g = df.groupby("yesterday_mit_done")[TARGET].agg(["sum", "count"])
        # Light smoothing toward the base rate for tiny groups.
        self.rates = ((g["sum"] + 2 * base) / (g["count"] + 2)).to_dict()
        self.base = float(base)
        return self

    def predict_proba(self, df):
        return df["yesterday_mit_done"].map(self.rates).fillna(self.base).to_numpy(float)


class Rolling7:
    """Last 7 days' MIT rate, shrunk toward the base rate."""

    name = "baseline_rolling_7d"

    def fit(self, df):
        self.base = float(df[TARGET].mean())
        return self

    def predict_proba(self, df):
        k = 3.0
        return ((7 * df["mit_rate_7"] + k * self.base) / (7 + k)).clip(0.01, 0.99).to_numpy(float)


def _preprocessor(numeric: list[str], categorical: list[str]) -> ColumnTransformer:
    return ColumnTransformer(
        [
            ("num", make_pipeline(SimpleImputer(strategy="median"), StandardScaler()), numeric),
            ("cat", OneHotEncoder(handle_unknown="ignore", drop="first"), categorical),
        ]
    )


class SklearnClassifier:
    def __init__(self, name: str, estimator, features: list[str] = FEATURES):
        self.name = name
        self.features = features
        numeric = [f for f in features if f in NUMERIC]
        categorical = [f for f in features if f in CATEGORICAL]
        self.pipeline = Pipeline([("prep", _preprocessor(numeric, categorical)), ("clf", estimator)])

    def fit(self, df):
        self.pipeline.fit(df[self.features], df[TARGET])
        return self

    def predict_proba(self, df):
        return self.pipeline.predict_proba(df[self.features])[:, 1]

    def coefficients(self) -> pd.Series | None:
        clf = self.pipeline.named_steps["clf"]
        if not hasattr(clf, "coef_"):
            return None
        names = self.pipeline.named_steps["prep"].get_feature_names_out()
        return pd.Series(clf.coef_[0], index=[n.split("__", 1)[1] for n in names]).sort_values()


# The handful of signals the design doc expected to matter most. With a few
# hundred days, a small well-regularised model beats a wide one.
COMPACT = [
    "planned_night_before",
    "is_weekend",
    "load",
    "mit_specific",
    "deadline_within_2d",
    "yesterday_mit_done",
    "mit_rate_7",
    "mit_category",
]


def logistic_compact() -> SklearnClassifier:
    return SklearnClassifier("logistic_compact", LogisticRegression(C=0.1, max_iter=2000), COMPACT)


def logistic_full() -> SklearnClassifier:
    return SklearnClassifier("logistic_full", LogisticRegression(C=0.1, max_iter=2000))


def gradient_boosting() -> SklearnClassifier:
    return SklearnClassifier(
        "gradient_boosting",
        HistGradientBoostingClassifier(
            max_depth=3, learning_rate=0.05, max_iter=200, l2_regularization=1.0, random_state=0
        ),
    )


def candidates() -> list:
    """Factories, not instances: each CV fold needs a fresh model."""
    return [BaseRate, Yesterday, Rolling7, logistic_compact, logistic_full, gradient_boosting]


# ------------------------------------------------------------ duration models


class CategoryMedian:
    """Baseline: this category's historical median time."""

    name = "baseline_category_median"

    def fit(self, df):
        return self

    def predict(self, df):
        return np.log(df["prior_cat_median"].to_numpy(float))


class SklearnRegressor:
    def __init__(self, name, estimator):
        self.name = name
        self.pipeline = Pipeline([("prep", _preprocessor(DURATION_NUMERIC, DURATION_CATEGORICAL)), ("reg", estimator)])

    def fit(self, df):
        self.pipeline.fit(df[DURATION_NUMERIC + DURATION_CATEGORICAL], df["log_minutes"])
        return self

    def predict(self, df):
        return self.pipeline.predict(df[DURATION_NUMERIC + DURATION_CATEGORICAL])


def duration_candidates() -> list:
    return [
        CategoryMedian,
        lambda: SklearnRegressor("ridge", Ridge(alpha=1.0)),
        lambda: SklearnRegressor(
            "gradient_boosting",
            HistGradientBoostingRegressor(max_depth=3, learning_rate=0.05, max_iter=200, random_state=0),
        ),
    ]
