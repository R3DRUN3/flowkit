#!/usr/bin/env bash
#
# backup.sh
#
# Takes a full, restorable backup of the Flowkit n8n stack:
#   1. Postgres: full pg_dumpall (roles + all databases) via the postgres
#      container, so a restore doesn't depend on the DB already existing.
#   2. n8n workflows: exported as one file per workflow (git-diff friendly)
#      via `n8n export:workflow --backup`.
#   3. n8n credentials: exported still ENCRYPTED with the instance's
#      N8N_ENCRYPTION_KEY (never decrypted) - safe to store, but useless
#      without that key on restore. The key itself is never touched by
#      this script; it must already be in your secrets store.
#
# Output: timestamped tarball under BACKUP_DIR (default ./backups),
# plus pruning of backups older than RETENTION_DAYS (default 14).
#
# Usage:
#   ./backup.sh
#   BACKUP_DIR=/mnt/backups RETENTION_DAYS=30 ./backup.sh
#
# Intended to run via cron/systemd timer as the same user that runs
# docker compose (needs docker exec rights on the running containers).

set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-compose/compose.yaml}"
ENV_FILE="${ENV_FILE:-.env}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="$(mktemp -d)"
STAGE="${WORKDIR}/flowkit-backup-${TIMESTAMP}"

trap 'rm -rf "$WORKDIR"' EXIT

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Env file not found at ${ENV_FILE}. Run from the repo root or set ENV_FILE." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

POSTGRES_CID="$(compose ps -q postgres)"
N8N_CID="$(compose ps -q n8n)"

if [[ -z "$POSTGRES_CID" || -z "$N8N_CID" ]]; then
  echo "postgres and/or n8n containers are not running. Start the stack before backing up." >&2
  exit 1
fi

mkdir -p "$STAGE/postgres" "$STAGE/workflows" "$STAGE/credentials"

# ---------------------------------------------------------------------------
# 1. Postgres: full logical dump (roles + all DBs)
# ---------------------------------------------------------------------------
echo "Dumping Postgres..."
docker exec -u postgres "$POSTGRES_CID" \
  pg_dumpall -U "${POSTGRES_USER}" > "${STAGE}/postgres/pg_dumpall.sql"
echo "  -> ${STAGE}/postgres/pg_dumpall.sql"

# ---------------------------------------------------------------------------
# 2. n8n workflows: one file per workflow, pretty-printed
# ---------------------------------------------------------------------------
echo "Exporting n8n workflows..."
docker exec -u node "$N8N_CID" \
  n8n export:workflow --backup --output=/tmp/workflows-backup >/dev/null
docker cp "${N8N_CID}:/tmp/workflows-backup/." "${STAGE}/workflows/"
docker exec -u node "$N8N_CID" rm -rf /tmp/workflows-backup
echo "  -> ${STAGE}/workflows/ ($(find "${STAGE}/workflows" -type f | wc -l) files)"

# ---------------------------------------------------------------------------
# 3. n8n credentials: exported ENCRYPTED (never --decrypted)
# ---------------------------------------------------------------------------
echo "Exporting n8n credentials (encrypted)..."
docker exec -u node "$N8N_CID" \
  n8n export:credentials --backup --output=/tmp/credentials-backup >/dev/null
docker cp "${N8N_CID}:/tmp/credentials-backup/." "${STAGE}/credentials/"
docker exec -u node "$N8N_CID" rm -rf /tmp/credentials-backup
echo "  -> ${STAGE}/credentials/ (still encrypted with N8N_ENCRYPTION_KEY)"

cat > "${STAGE}/MANIFEST.txt" <<EOF
Flowkit backup
==============
Created (UTC):     ${TIMESTAMP}
n8n image:         $(compose images n8n --format json 2>/dev/null | grep -o '"Repository":"[^"]*","Tag":"[^"]*"' || echo unknown)
Postgres database: ${POSTGRES_DB}

Restore requires the SAME N8N_ENCRYPTION_KEY that was active when this
backup was taken. That key is NOT included in this backup - retrieve it
from your secrets store separately. Without it, credentials.json files
in credentials/ cannot be decrypted and are useless.

Contents:
  postgres/pg_dumpall.sql   - full Postgres dump (roles + all databases)
  workflows/*.json          - one file per workflow
  credentials/*.json        - one file per credential, still encrypted
EOF

# ---------------------------------------------------------------------------
# Package + prune
# ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
ARCHIVE="${BACKUP_DIR}/flowkit-backup-${TIMESTAMP}.tar.gz"
tar -czf "$ARCHIVE" -C "$WORKDIR" "flowkit-backup-${TIMESTAMP}"
chmod 600 "$ARCHIVE"
echo "Backup archive: ${ARCHIVE}"

if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  find "$BACKUP_DIR" -maxdepth 1 -name 'flowkit-backup-*.tar.gz' -mtime "+${RETENTION_DAYS}" -print -delete \
    | sed 's/^/Pruned old backup: /' || true
fi

echo "Done."