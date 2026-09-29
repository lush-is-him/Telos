#!/usr/bin/env bash
# Weekly Postgres dump with retention and an optional second copy.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a

mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/telos-$(date +%F).sql.gz"
docker compose exec -T db pg_dump -U telos -d telos --clean --if-exists | gzip > "$out.tmp"
# An empty or truncated dump must never replace a good one.
gzip -t "$out.tmp" && [ "$(stat -c%s "$out.tmp")" -gt 1000 ]
mv "$out.tmp" "$out"
echo "wrote $out ($(du -h "$out" | cut -f1))"

ls -1t "$BACKUP_DIR"/telos-*.sql.gz | tail -n +"$((${KEEP_WEEKS:-8} + 1))" | xargs -r rm --

if [ -n "${BACKUP_MIRROR:-}" ]; then
  if [ -d "$BACKUP_MIRROR" ]; then
    cp "$out" "$BACKUP_MIRROR/"
    echo "mirrored to $BACKUP_MIRROR"
  else
    echo "WARNING: mirror $BACKUP_MIRROR not mounted; only one copy this week" >&2
  fi
fi
