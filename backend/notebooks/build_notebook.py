"""Builds and executes notebooks/telos_analysis.ipynb (so outputs are committed
and readable on GitHub). Run from backend/: python notebooks/build_notebook.py"""

from pathlib import Path

import nbformat as nbf
from nbconvert.preprocessors import ExecutePreprocessor

md, code = nbf.v4.new_markdown_cell, nbf.v4.new_code_cell

cells = [
    md(
        "# Telos: what predicts getting the one important thing done?\n\n"
        "Telos logs one *most important task* (MIT) per day, planned the night before, plus timers. "
        "This notebook walks through the analysis on a **synthetic year** from `telos.ml.simulate` — a seeded "
        "behavioural simulator with planted effects — so every step can be checked against known truth. "
        "Point `DATABASE_URL` at the live Postgres to run it on real data.\n\n"
        "**Question:** at planning time (the evening before), how likely is tomorrow's MIT to get done, and "
        "which planning habits move that probability?"
    ),
    code(
        "import os\n"
        "from datetime import date\n"
        "import numpy as np, pandas as pd\n"
        "import matplotlib.pyplot as plt\n"
        "from telos.db import make_engine\n"
        "from telos.ml.data import load_tables\n"
        "from telos.ml.simulate import simulate, TRUE_EFFECTS\n"
        "from telos.ml import report\n"
        "report._style()\n"
        "pd.set_option('display.precision', 3)\n"
        "import warnings\n"
        "warnings.filterwarnings('ignore', message='Found unknown categories')  # a category unseen in an early fold\n\n"
        "url = os.environ.get('DATABASE_URL')\n"
        "if url is None:  # synthetic demo\n"
        "    engine = make_engine('sqlite:///:memory:')\n"
        "    simulate(engine, days=365, seed=7, end=date(2026, 9, 28))\n"
        "else:\n"
        "    engine = make_engine(url)\n"
        "with engine.connect() as conn:\n"
        "    t = load_tables(conn)\n"
        "{k: len(getattr(t, k)) for k in ['day', 'task', 'study_item', 'time_session', 'deadline']}"
    ),
    md("## 1. One row per day\n\nEvery feature is known at planning time or comes strictly from earlier days — see `features.py` and the leakage test in `tests/test_features.py`."),
    code(
        "from telos.ml.features import daily_features, FEATURES\n"
        "f = daily_features(t)\n"
        "print(f'{len(f)} MIT days, completion rate {f.y.mean():.1%}')\n"
        "f[['date', 'planned_night_before', 'is_weekend', 'load', 'mit_specific', 'yesterday_mit_done', 'mit_rate_7', 'streak', 'y']].head(8)"
    ),
    md("## 2. Descriptive first\n\nRates with 95% Wilson intervals. These are *associations* — days planned the night before also tend to follow good days."),
    code(
        "fig, (a, b) = plt.subplots(1, 2, figsize=(10, 3.4), gridspec_kw={'width_ratios': [7, 3]})\n"
        "w = report.weekday_table(f); report._rate_bars(a, w.index, w['done'], w['n'], 'MIT completion by weekday')\n"
        "p = report.planning_table(f); report._rate_bars(b, ['Same day', 'Night before'], p['done'], p['n'], '…by planning time', ylabel='')\n"
        "plt.tight_layout()"
    ),
    code(
        "# Is the night-before gap just momentum? Stratify by whether yesterday's MIT was done.\n"
        "(f.groupby(['yesterday_mit_done', 'planned_night_before'])['y']\n"
        "   .agg(rate='mean', n='size').unstack('planned_night_before'))"
    ),
    code(
        "g = f.groupby(['yesterday_mit_done', 'planned_night_before'])['y'].mean().unstack()\n"
        "gap = (g[1] - g[0]).rename('night-before minus same-day')\n"
        "print(gap.round(3).to_string())\n"
        "print('Gap holds in both strata, so it is not only momentum.' if (gap > 0).all() else 'Gap does not hold in every stratum.')"
    ),
    md("Other confounders could remain; the model below adjusts for several at once."),
    md("## 3. Forecasting, evaluated honestly\n\nWalk-forward CV: train on the past, score the next 14 days, roll forward. Baselines get the same treatment."),
    code(
        "from telos.ml.train import train\n"
        "r = train(t)\n"
        "r.metrics"
    ),
    code(
        "d, lo, hi = r.vs_baseline\n"
        "print(f'{r.best} vs best baseline: Brier {d:+.4f}  (95% block-bootstrap CI {lo:+.4f} to {hi:+.4f})')\n"
        "print('CI excludes zero' if hi < 0 else 'CI includes zero: better on average, not conclusive for this one year')\n"
        "print('shipped:', r.final.name)"
    ),
    md("### Is that stable? Five synthetic users\n\nOne year is one draw. Re-simulate with different seeds and repeat the whole evaluation."),
    code(
        "rows = []\n"
        "for seed in [7, 11, 23, 42, 99]:\n"
        "    e = make_engine('sqlite:///:memory:')\n"
        "    simulate(e, days=365, seed=seed, end=date(2026, 9, 28))\n"
        "    with e.connect() as c:\n"
        "        rr = train(load_tables(c))\n"
        "    m = rr.metrics.set_index('model')['brier']\n"
        "    d_, lo_, hi_ = rr.vs_baseline\n"
        "    rows.append({'seed': seed, 'best_model': rr.best, 'model_brier': m[rr.best],\n"
        "                 'best_baseline_brier': m[m.index.str.startswith('baseline')].min(),\n"
        "                 'diff': d_, 'ci_low': lo_, 'ci_high': hi_, 'ci_excludes_0': hi_ < 0})\n"
        "robust = pd.DataFrame(rows)\n"
        "robust"
    ),
    md("Why does the compact model beat the full one and gradient boosting? ~300 rows. Extra features (7 weekday dummies, overlapping rolling rates) add variance faster than signal; boosting overfits the early folds, which only have 60–100 training days."),
    code(
        "from telos.ml.evaluate import calibration_table\n"
        "calibration_table(r.oof[r.best], bins=5)"
    ),
    md("## 4. Where is it wrong?"),
    code(
        "oof = r.oof[r.best].merge(f[['date', 'is_weekend', 'planned_night_before', 'mit_category']], on='date')\n"
        "oof['sq_err'] = (oof.p - oof.y) ** 2\n"
        "pd.concat({\n"
        "    'by weekend': oof.groupby('is_weekend')['sq_err'].agg(['mean', 'size']),\n"
        "    'by planning': oof.groupby('planned_night_before')['sq_err'].agg(['mean', 'size']),\n"
        "    'by category': oof.groupby('mit_category')['sq_err'].agg(['mean', 'size']),\n"
        "})"
    ),
    md("## 5. What-if: plan it the night before\n\nContrast the model's prediction for each real day with the same day flipped to *planned the night before*. This is a model-based contrast, not a causal estimate — the simulator knows the truth, real data won't."),
    code(
        "same_day = f[f.planned_night_before == 0].copy()\n"
        "flipped = same_day.assign(planned_night_before=1)\n"
        "m = r.final.model\n"
        "lift = m.predict_proba(flipped) - m.predict_proba(same_day)\n"
        "print(f'{len(same_day)} same-day plans; mean predicted lift if planned the night before: {lift.mean():+.1%}')"
    ),
    md("## 6. Sanity check against the planted truth"),
    code(
        "rec = report.effect_recovery(f, TRUE_EFFECTS)\n"
        "print(f\"{rec.true_in_ci.sum()}/{len(rec)} true effects inside their 95% CI\")\n"
        "rec"
    ),
    md("## 7. How long will a task take?\n\nPer-category median vs learned regressors, errors in minutes."),
    code("r.duration_metrics"),
    md("## Takeaways (computed from the results above)"),
    code(
        "from IPython.display import Markdown\n"
        "wins = int((robust['diff'] < 0).sum()); sig = int(robust['ci_excludes_0'].sum())\n"
        "ece = r.metrics.set_index('model').loc[r.best, 'ece']\n"
        "dm = r.duration_metrics.set_index('model')['mae_minutes']\n"
        "dur_gap = dm.drop('baseline_category_median').min() - dm['baseline_category_median']\n"
        "Markdown('\\n'.join([\n"
        "    f'- The best model beat the best baseline for **{wins}/5** synthetic users; the 95% CI excluded zero for **{sig}/5**. '\n"
        "    'With one year of data the gain is real but modest, and should firm up as days accumulate.',\n"
        "    f'- Calibration error (ECE) is {ece:.3f}, so the probability can be shown to the user as-is.',\n"
        "    f'- Durations: the best learned model differs from the per-category median by {dur_gap:+.1f} min MAE, '\n"
        "    + ('so the app uses the simpler median.' if dur_gap > -1 else 'so a learned model is worth shipping.'),\n"
        "    '- Real data has no ground truth for the section 6 check, which is why the pipeline is validated on synthetic data first.',\n"
        "]))"
    ),
]

nb = nbf.v4.new_notebook(cells=cells, metadata={"kernelspec": {"name": "python3", "display_name": "Python 3", "language": "python"}})
ExecutePreprocessor(timeout=600, kernel_name="python3").preprocess(nb, {"metadata": {"path": str(Path(__file__).parent.parent)}})
out = Path(__file__).parent / "telos_analysis.ipynb"
nbf.write(nb, out)
print("wrote", out)
