#!/usr/bin/env bash
# One-time setup on the Ubuntu PC. Expects the repo at /opt/telos.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "cp .env.example .env and fill it in first"; exit 1; }
chmod +x backup.sh retrain.sh restore.sh
sudo systemctl enable --now docker
docker compose up -d --build
sudo cp systemd/telos-*.service systemd/telos-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now telos-backup.timer telos-train.timer
systemctl list-timers 'telos-*'
