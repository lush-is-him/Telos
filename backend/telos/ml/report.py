"""Generates reports/REPORT.md plus figures from the data and a TrainResult."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

from telos.ml.data import Tables  # noqa: E402
from telos.ml.evaluate import calibration_table  # noqa: E402
from telos.ml.train import TrainResult  # noqa: E402

# Reference palette (light surface): categorical slots 1-2, text inks, grid.
BLUE, ORANGE = "#2a78d6", "#eb6834"
INK, INK_2, MUTED, GRID, SURFACE = "#0b0b0b", "#52514e", "#8a8984", "#e6e5e0", "#fcfcfb"
WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def _style() -> None:
    plt.rcParams.update(
        {
            "figure.facecolor": SURFACE,
            "axes.facecolor": SURFACE,
            "savefig.facecolor": SURFACE,
            "axes.edgecolor": GRID,
            "axes.labelcolor": INK_2,
            "axes.titlecolor": INK,
            "axes.titlesize": 12,
            "axes.titleweight": "bold",
            "axes.titlelocation": "left",
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.grid": True,
            "grid.color": GRID,
            "grid.linewidth": 0.8,
            "xtick.color": INK_2,
            "ytick.color": INK_2,
            "font.size": 10,
            "legend.frameon": False,
        }
    )


def wilson(k: np.ndarray, n: np.ndarray, z: float = 1.96) -> tuple[np.ndarray, np.ndarray]:
    """95% Wilson interval — behaves on small n, unlike the normal approximation."""
    n = np.maximum(n, 1)
    p = k / n
    centre = (p + z**2 / (2 * n)) / (1 + z**2 / n)
    half = z * np.sqrt(p * (1 - p) / n + z**2 / (4 * n**2)) / (1 + z**2 / n)
    return centre - half, centre + half


def _rate_bars(ax, labels, k, n, title, ylabel="MIT completion rate") -> None:
    k, n = np.asarray(k, float), np.asarray(n, float)
    rate = np.divide(k, n, out=np.zeros_like(k), where=n > 0)
    lo, hi = wilson(k, n)
    x = np.arange(len(labels))
    ax.bar(x, rate, width=0.6, color=BLUE, zorder=2)
    ax.errorbar(x, rate, yerr=[rate - lo, hi - rate], fmt="none", ecolor=INK_2, elinewidth=1.2, capsize=3, zorder=3)
    for xi, ni in zip(x, n, strict=True):
        ax.text(xi, 0.02, f"n={int(ni)}", ha="center", va="bottom", color=SURFACE, fontsize=8, zorder=4)
    ax.set_xticks(x, labels)
    ax.set_ylim(0, 1)
    ax.yaxis.set_major_formatter(matplotlib.ticker.PercentFormatter(1.0))
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(axis="x", visible=False)


def _save(fig, path: Path) -> str:
    fig.tight_layout()
    fig.savefig(path, dpi=160)
    plt.close(fig)
    return path.name


# ------------------------------------------------------------------ analyses


def weekday_table(feats: pd.DataFrame) -> pd.DataFrame:
    g = feats.groupby(feats["date"].dt.dayofweek)["y"].agg(done="sum", n="size").reindex(range(7), fill_value=0)
    g.index = WEEKDAYS
    return g


def planning_table(feats: pd.DataFrame) -> pd.DataFrame:
    g = feats.groupby("planned_night_before")["y"].agg(done="sum", n="size").reindex([0, 1], fill_value=0)
    g.index = ["Planned same day", "Planned night before"]
    return g


def subject_table(t: Tables) -> pd.DataFrame:
    s = t.study_item
    g = s.groupby("subject")["work_completed"].agg(done=lambda x: (x == "done").sum(), n="size")
    return g.sort_values("n", ascending=False)


def hours_table(t: Tables) -> pd.Series:
    ts = t.time_session.dropna(subset=["minutes"])
    return ts.groupby(ts["started_at"].dt.hour)["minutes"].sum().reindex(range(24), fill_value=0)


def effect_recovery(feats: pd.DataFrame, true_effects: dict[str, float]) -> pd.DataFrame:
    """Refit the simulator's exact design with a plain (unregularised) logistic
    regression and compare estimates to the planted effects, with Wald 95% CIs."""
    X = pd.DataFrame(
        {
            "planned_night_before": feats["planned_night_before"],
            "yesterday_mit_done": feats["yesterday_mit_done"],
            "is_weekend": feats["is_weekend"],
            "load_above_2": (feats["load"] - 2).clip(lower=0),
            "specific_title": feats["mit_specific"],
            "deadline_within_2d": feats["deadline_within_2d"] * feats["mit_category"].isin(["study", "project"]),
            "category_admin": (feats["mit_category"] == "admin").astype(int),
            "category_project": (feats["mit_category"] == "project").astype(int),
            "category_other": (feats["mit_category"] == "other").astype(int),
            "momentum_7d": (feats["mit_rate_7"] - 0.5) * 2,
        }
    ).astype(float)
    Xm = np.column_stack([np.ones(len(X)), X.to_numpy()])
    y = feats["y"].to_numpy(float)
    beta = np.zeros(Xm.shape[1])
    for _ in range(50):  # Newton-Raphson
        p = 1 / (1 + np.exp(-Xm @ beta))
        W = p * (1 - p)
        H = Xm.T @ (Xm * W[:, None]) + 1e-6 * np.eye(Xm.shape[1])
        step = np.linalg.solve(H, Xm.T @ (y - p))
        beta += step
        if np.abs(step).max() < 1e-8:
            break
    se = np.sqrt(np.diag(np.linalg.inv(H)))
    names = ["intercept", *X.columns]
    out = pd.DataFrame({"true": [true_effects.get(n, np.nan) for n in names], "estimate": beta, "se": se}, index=names)
    out["ci_low"], out["ci_high"] = out["estimate"] - 1.96 * out["se"], out["estimate"] + 1.96 * out["se"]
    out["true_in_ci"] = (out["true"] >= out["ci_low"]) & (out["true"] <= out["ci_high"])
    return out


# ------------------------------------------------------------------ figures


def fig_weekday_and_planning(feats, out: Path) -> str:
    fig, (a, b) = plt.subplots(1, 2, figsize=(10, 3.6), gridspec_kw={"width_ratios": [7, 3]})
    w = weekday_table(feats)
    _rate_bars(a, w.index, w["done"], w["n"], "MIT completion by weekday")
    p = planning_table(feats)
    _rate_bars(b, ["Same day", "Night before"], p["done"], p["n"], "…by when it was planned", ylabel="")
    return _save(fig, out / "fig_descriptive.png")


def fig_hours(t: Tables, out: Path) -> str:
    h = hours_table(t) / 60
    fig, ax = plt.subplots(figsize=(10, 3))
    ax.bar(h.index, h.to_numpy(), width=0.8, color=BLUE, zorder=2)
    ax.set_xticks(range(0, 24, 2), [f"{i:02d}:00" for i in range(0, 24, 2)])
    ax.set_ylabel("Hours logged")
    ax.set_title("When work actually happens (timer start hour, local time)")
    ax.grid(axis="x", visible=False)
    return _save(fig, out / "fig_hours.png")


def fig_subjects(t: Tables, out: Path) -> str:
    s = subject_table(t)
    fig, ax = plt.subplots(figsize=(6, 3.2))
    _rate_bars(ax, s.index, s["done"], s["n"], "Study items marked done, by subject", ylabel="Done rate")
    ax.tick_params(axis="x", labelsize=9)
    return _save(fig, out / "fig_subjects.png")


def fig_calibration(result: TrainResult, baseline: str, out: Path) -> str:
    fig, ax = plt.subplots(figsize=(5, 4.6))
    ax.plot([0, 1], [0, 1], color=MUTED, lw=1, ls=(0, (4, 3)), zorder=1)
    ax.text(0.97, 0.92, "perfect", color=MUTED, ha="right", fontsize=8, rotation=38)
    for name, colour in [(result.best, BLUE), (baseline, ORANGE)]:
        c = calibration_table(result.oof[name], bins=5)
        ax.plot(
            c["p_mean"], c["y_rate"], color=colour, lw=2, marker="o", ms=7, mec=SURFACE, mew=2, label=name, zorder=3
        )
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_xlabel("Predicted P(MIT done)")
    ax.set_ylabel("Observed rate")
    ax.set_title("Calibration (out-of-fold, quintiles)")
    ax.legend(loc="upper left")
    return _save(fig, out / "fig_calibration.png")


def fig_coefficients(result: TrainResult, out: Path) -> str | None:
    model = result.final.model if result.final else None
    coefs = model.coefficients() if hasattr(model, "coefficients") else None
    if coefs is None:
        return None
    fig, ax = plt.subplots(figsize=(6, 0.32 * len(coefs) + 1))
    colours = [BLUE if v > 0 else ORANGE for v in coefs]
    ax.barh(coefs.index, coefs.to_numpy(), color=colours, height=0.6, zorder=2)
    ax.axvline(0, color=INK_2, lw=1)
    ax.set_xlabel("Standardised log-odds (category vs admin)")
    ax.set_title("What moves the forecast")
    ax.grid(axis="y", visible=False)
    return _save(fig, out / "fig_coefficients.png")


# ------------------------------------------------------------------ markdown


def _md_table(df: pd.DataFrame, floatfmt: str = "{:.3f}") -> str:
    cols = list(df.columns)
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for _, r in df.iterrows():
        cells = [floatfmt.format(v) if isinstance(v, (float, np.floating)) else str(v) for v in r]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def write_report(t: Tables, result: TrainResult, out: Path, synthetic: bool, true_effects: dict | None = None) -> Path:
    _style()
    out.mkdir(parents=True, exist_ok=True)
    f = result.features
    lines = ["# Telos — analysis report", ""]
    lines.append(f"_Generated {datetime.now(UTC):%Y-%m-%d %H:%M} UTC._ ")
    if synthetic:
        lines += [
            "",
            "> **Synthetic data.** These numbers come from `telos.ml.simulate`, a seeded behavioural "
            "simulator with planted effects. They demonstrate and sanity-check the pipeline; they say "
            "nothing about real behaviour. Re-run `python -m telos.ml report` against the live database "
            "for real results.",
        ]
    n_days = f["date"].nunique() if len(f) else 0
    lines += [
        "",
        "## Data",
        "",
        f"- {n_days} days with an MIT, spanning {f['date'].min():%Y-%m-%d} → {f['date'].max():%Y-%m-%d}"
        if n_days
        else "- No MIT days yet",
        f"- MIT completion rate: {f['y'].mean():.1%}" if n_days else "",
        f"- {len(t.task)} tasks, {len(t.study_item)} study items, {len(t.time_session)} timer sessions",
        "",
        "## Descriptive",
        "",
        f"![weekday and planning]({fig_weekday_and_planning(f, out)})",
        "",
        "Bars are completion rates with 95% Wilson intervals. Unadjusted: days planned the night before also "
        "differ in other ways (they cluster after good days), which is why the model below matters.",
        "",
        f"![hours]({fig_hours(t, out)})",
        "",
        f"![subjects]({fig_subjects(t, out)})",
        "",
    ]

    if result.final is None:
        lines += ["## Model", "", f"Not trained: fewer than 60 MIT days so far ({n_days})."]
    else:
        baseline = result.metrics.loc[result.metrics["model"].str.startswith("baseline"), "model"].iloc[0]
        d, lo, hi = result.vs_baseline
        verdict = (
            "The interval excludes zero: the model is reliably better than the best baseline."
            if hi < 0
            else "The interval includes zero: on this much data the gain over the baseline is not conclusive."
        )
        lines += [
            "## Forecast: will tomorrow's MIT get done?",
            "",
            "Walk-forward evaluation: train on every day before a cutoff, score the next 14 days, move the cutoff, "
            "repeat. Every prediction below was made without seeing its own future. Lower Brier/log-loss is better.",
            "",
            _md_table(result.metrics, "{:.4f}"),
            "",
            f"**{result.best}** vs **{baseline}**: Brier difference {d:+.4f} (95% block-bootstrap CI {lo:+.4f} to {hi:+.4f}, "
            f"7-day blocks to respect autocorrelation). {verdict} Shipped to the app: **{result.final.name}**.",
            "",
            f"![calibration]({fig_calibration(result, baseline, out)})",
            "",
        ]
        coef_fig = fig_coefficients(result, out)
        if coef_fig:
            lines += [f"![coefficients]({coef_fig})", ""]

    if synthetic and true_effects and len(f):
        rec = effect_recovery(f, true_effects).reset_index(names="effect")
        covered = int(rec["true_in_ci"].sum())
        lines += [
            "## Pipeline check: are the planted effects recovered?",
            "",
            "Refit the simulator's exact design (unregularised logistic, Wald 95% CI). If the feature pipeline "
            "leaked or mis-aligned days, the estimates would drift away from the truth. "
            f"{covered}/{len(rec)} true values fall inside their interval.",
            "",
            _md_table(rec[["effect", "true", "estimate", "ci_low", "ci_high", "true_in_ci"]], "{:+.2f}"),
            "",
        ]

    if result.duration_metrics is not None:
        best_dur = result.duration_metrics.iloc[0]["model"]
        lines += [
            "## How long will it take?",
            "",
            "Minutes per completed task, walk-forward. Errors are in minutes.",
            "",
            _md_table(result.duration_metrics, "{:.2f}"),
            "",
            f"Best: **{best_dur}**."
            + (
                " A per-category median is as good as the learned models, so the app should use the simple rule."
                if best_dur.startswith("baseline")
                or abs(
                    result.duration_metrics.iloc[0]["mae_minutes"]
                    - result.duration_metrics.set_index("model").loc["baseline_category_median", "mae_minutes"]
                )
                < 0.5
                else ""
            ),
            "",
        ]

    path = out / "REPORT.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path
