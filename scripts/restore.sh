#!/usr/bin/env bash
#
# restore.sh
#
# Restores a Flowkit backup produced by backup.sh onto a running stack.
#
# IMPORTANT:
#   - The target n8n container MUST already have the same N8N_ENCRYPTION_KEY
#     that was active when the backup was taken, set via .env, BEFORE you
#     run this script. If it doesn't match, credentials will import but
#     stay permanently undecryptable - this is not reversible after the
#     fact, so double-check before proceeding.
#   - This is destructive to the current Postgres database (roles/dbs from
#     the dump are (re)created; matching workflow/credential IDs are
#     overwritten on import). Take a fresh backup of the CURRENT state
#     first if you're not restoring onto a throwaway/fresh instance.
#
# Usage:
#   ./restore.sh <path-to-backup.tar.gz>

set -euo pipefail

ARCHIVE="${1:?Usage: restore.sh <path-to-backup.tar.gz>}"
COMPOSE_FILE="${COMPOSE_FILE:-compose/compose.yaml}"
ENV_FILE="${ENV_FILE:-.env}"

[[ -f "$ARCHIVE" ]] || { echo "Backup archive not found: ${ARCHIVE}" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "Env file not found at ${ENV_FILE}." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
tar -xzf "$ARCHIVE" -C "$WORKDIR"
STAGE="$(find "$WORKDIR" -maxdepth 1 -type d -name 'flowkit-backup-*')"
[[ -n "$STAGE" ]] || { echo "Unexpected archive layout." >&2; exit 1; }

echo "Restoring from: ${STAGE}"
cat "${STAGE}/MANIFEST.txt" || true
echo
read -r -p "This will overwrite the current Postgres data and matching workflows/credentials. Continue? [y/N] " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

POSTGRES_CID="$(compose ps -q postgres)"
N8N_CID="$(compose ps -q n8n)"
[[ -n "$POSTGRES_CID" && -n "$N8N_CID" ]] || { echo "postgres and/or n8n containers are not running." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Restore Postgres
# ---------------------------------------------------------------------------
echo "Restoring Postgres from pg_dumpall.sql..."
docker cp "${STAGE}/postgres/pg_dumpall.sql" "${POSTGRES_CID}:/tmp/pg_dumpall.sql"
docker exec -u postgres "$POSTGRES_CID" \
  psql -U "${POSTGRES_USER}" -d postgres -f /tmp/pg_dumpall.sql
docker exec -u postgres "$POSTGRES_CID" rm -f /tmp/pg_dumpall.sql
echo "  Postgres restored."

echo "Restarting n8n so it picks up the restored database..."
compose restart n8n
compose exec -T n8n sh -c 'until wget -qO- http://localhost:6789/healthz >/dev/null 2>&1; do sleep 1; done'

# ---------------------------------------------------------------------------
# 2. Import workflows
# ---------------------------------------------------------------------------
echo "Importing workflows..."
docker cp "${STAGE}/workflows" "${N8N_CID}:/tmp/workflows-restore"
docker exec -u node "$N8N_CID" n8n import:workflow --separate --input=/tmp/workflows-restore
docker exec -u node "$N8N_CID" rm -rf /tmp/workflows-restore
echo "  Workflows imported."

# ---------------------------------------------------------------------------
# 3. Import credentials (still encrypted - requires matching N8N_ENCRYPTION_KEY)
# ---------------------------------------------------------------------------
echo "Importing credentials..."
docker cp "${STAGE}/credentials" "${N8N_CID}:/tmp/credentials-restore"
docker exec -u node "$N8N_CID" n8n import:credentials --separate --input=/tmp/credentials-restore
docker exec -u node "$N8N_CID" rm -rf /tmp/credentials-restore
echo "  Credentials imported."

echo
echo "Restore complete. Verify in the n8n editor that workflows run and"
echo "credentials are usable (open one and check it doesn't ask to reconnect)."
echo "If credentials fail to decrypt, N8N_ENCRYPTION_KEY does not match"
echo "the key used when this backup was taken."
