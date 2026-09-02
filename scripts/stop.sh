#!/usr/bin/env bash
#
# stop.sh
#
# Stops the Flowkit n8n stack via Docker Compose without deleting any
# data (containers are stopped/removed, but named volumes - n8n_data,
# db_storage, traefik_data - persist).
#
# Usage:
#   ./scripts/stop.sh          # stop the stack
#   ./scripts/stop.sh --down   # same, but also remove the containers
#                                (default `docker compose down` behavior;
#                                 volumes are still kept)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/compose/compose.yaml}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env not found at ${ENV_FILE}." >&2
  exit 1
fi

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

if [[ "${1:-}" == "--down" ]]; then
  echo "Stopping and removing containers (volumes are kept)..."
  compose down
else
  echo "Stopping containers (kept, not removed)..."
  compose stop
fi

compose ps