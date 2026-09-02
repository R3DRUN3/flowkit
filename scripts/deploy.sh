#!/usr/bin/env bash
#
# deploy.sh
#
# Starts (or updates) the Flowkit n8n stack via Docker Compose.
#
# What it does:
#   1. Sanity-checks that .env and the compose file exist.
#   2. Pulls the latest images for the pinned tags in compose.yaml.
#   3. Starts everything in the background (docker compose up -d).
#   4. Waits for n8n to report healthy on /healthz before exiting.
#
# Usage:
#   ./scripts/deploy.sh
#
# Run from anywhere; paths below are relative to the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/compose/compose.yaml}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env not found at ${ENV_FILE}." >&2
  echo "Copy .env.example to .env and fill in real values first." >&2
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: compose file not found at ${COMPOSE_FILE}." >&2
  exit 1
fi

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

echo "Pulling images..."
compose pull

echo "Starting stack..."
compose up -d

echo "Waiting for n8n to become healthy..."
for i in $(seq 1 30); do
  if compose exec -T n8n wget -qO- --no-check-certificate https://localhost:6789/healthz >/dev/null 2>&1; then
    echo "n8n is up."
    compose ps
    exit 0
  fi
  sleep 2
done

echo "n8n did not become healthy within 60s. Check logs with:" >&2
echo "  docker compose -f ${COMPOSE_FILE} --env-file ${ENV_FILE} logs n8n" >&2
exit 1