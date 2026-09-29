"""python -m telos.ml {simulate,train,report,demo}

simulate  fill a database with a synthetic year
train     walk-forward CV, save the shipped model (weekly cron)
report    train + write reports/REPORT.md with figures
demo      simulate into a fresh SQLite file, then report
"""

from __future__ import annotations

import argparse
import os
from datetime import date
from pathlib import Path

from telos.db import make_engine


def main() -> None:
    ap = argparse.ArgumentParser(prog="python -m telos.ml")
    ap.add_argument("command", choices=["simulate", "train", "report", "demo"])
    ap.add_argument("--db", default=os.environ.get("DATABASE_URL", "sqlite:///telos.db"))
    ap.add_argument(
        "--model-path", type=Path, default=Path(os.environ.get("TELOS_MODEL_PATH", "artifacts/mit_model.joblib"))
    )
    ap.add_argument("--out", type=Path, default=Path("../reports"))
    ap.add_argument("--tz", default=os.environ.get("TELOS_TZ", "UTC"))
    ap.add_argument("--days", type=int, default=365)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--end", type=date.fromisoformat, default=None, help="last simulated day (default: today)")
    ap.add_argument("--synthetic", action="store_true", help="label the report as synthetic")
    args = ap.parse_args()

    from telos.ml.data import load_tables
    from telos.ml.simulate import TRUE_EFFECTS, simulate
    from telos.ml.train import save, train

    if args.command == "demo":
        path = Path("demo.db")
        path.unlink(missing_ok=True)
        args.db, args.synthetic = f"sqlite:///{path}", True

    engine = make_engine(args.db)

    if args.command in ("simulate", "demo"):
        counts = simulate(engine, days=args.days, seed=args.seed, tz=args.tz, end=args.end)
        print("simulated:", counts)
        if args.command == "simulate":
            return

    with engine.connect() as conn:
        tables = load_tables(conn, args.tz)
    result = train(tables)
    if result.final is None:
        print(f"Only {len(result.features)} MIT days; need 60 before training.")
    else:
        save(result, args.model_path)
        print(result.metrics.round(4).to_string(index=False))
        print(f"shipped {result.final.name} -> {args.model_path}")

    if args.command in ("report", "demo"):
        from telos.ml.report import write_report

        path = write_report(
            tables, result, args.out, synthetic=args.synthetic, true_effects=TRUE_EFFECTS if args.synthetic else None
        )
        print("report:", path)


if __name__ == "__main__":
    main()
