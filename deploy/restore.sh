#!/usr/bin/env bash
# Restore a dump:  ./restore.sh /var/backups/telos/telos-2026-10-04.sql.gz
set -euo pipefail
cd "$(dirname "$0")"
[ -f "${1:-}" ] || { echo "usage: $0 <dump.sql.gz>"; exit 1; }
read -rp "Overwrite the live telos database with $1? [y/N] " ok
[ "$ok" = y ] || exit 1
gunzip -c "$1" | docker compose exec -T db psql -U telos -d telos -v ON_ERROR_STOP=1
