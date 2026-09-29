#!/usr/bin/env bash
# Weekly: retrain the forecast on all synced data and refresh the report.
set -euo pipefail
cd "$(dirname "$0")"
docker compose exec -T api python -m telos.ml report --out /data/reports
