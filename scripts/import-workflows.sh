#!/usr/bin/env bash
#
# import-workflows.sh
#
# Restores Flowkit workflows and their referenced credentials into n8n.
#
# Credentials are imported first so that workflow credential references
# are resolved correctly.
#
# By default, workflows are imported inactive.
#
# Use --activate to publish all imported, non-archived workflows and
# restart n8n so that the changes take effect and production webhooks
# are registered.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/compose/compose.yaml}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
WORKFLOWS_DIR="${REPO_ROOT}/workflows"
CREDENTIALS_FILE="${REPO_ROOT}/credentials/credentials.json"

ACTIVATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --activate)
      ACTIVATE=true
      ;;
    --help|-h)
      echo "Usage: $0 [--activate]"
      echo
      echo "Restores Flowkit workflows and credentials into n8n."
      echo
      echo "Options:"
      echo "  --activate    Publish all imported, non-archived workflows,"
      echo "                restart n8n, and register production webhooks."
      echo "  --help, -h    Show this help message."
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      echo "Usage: $0 [--activate]" >&2
      exit 1
      ;;
  esac

  shift
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env not found at ${ENV_FILE}." >&2
  echo "Copy .env.example to .env and fill in real values first." >&2
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: compose file not found at ${COMPOSE_FILE}." >&2
  exit 1
fi

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  echo "Error: credentials backup not found at ${CREDENTIALS_FILE}." >&2
  exit 1
fi

if [[ ! -d "$WORKFLOWS_DIR" ]] || ! compgen -G "${WORKFLOWS_DIR}/*.json" >/dev/null; then
  echo "Error: no workflow JSON files found in ${WORKFLOWS_DIR}." >&2
  exit 1
fi

compose() {
  docker compose \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    "$@"
}

echo "Importing credentials..."

compose exec -T n8n \
  n8n import:credentials \
  --input=/backup/credentials/credentials.json

echo "Importing workflows..."

compose exec -T n8n \
  n8n import:workflow \
  --separate \
  --input=/backup/workflows

if [[ "$ACTIVATE" == true ]]; then
  echo "Activating workflows..."

  mapfile -t WORKFLOW_INFO < <(
    python3 - "$WORKFLOWS_DIR" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])

for path in sorted(directory.glob("*.json")):
    with path.open("r", encoding="utf-8") as f:
        workflow = json.load(f)

    workflow_id = workflow.get("id")
    workflow_name = workflow.get("name", path.stem)

    if not workflow_id:
        print(
            f"Warning: workflow '{workflow_name}' has no ID and will be skipped.",
            file=sys.stderr,
        )
        continue

    if workflow.get("isArchived", False):
        print(
            f"Skipping archived workflow: {workflow_name}",
            file=sys.stderr,
        )
        continue

    print(f"{workflow_id}|{workflow_name}")
PY
  )

  if [[ ${#WORKFLOW_INFO[@]} -eq 0 ]]; then
    echo "No non-archived workflows to activate."
  else
    for workflow_info in "${WORKFLOW_INFO[@]}"; do
      workflow_id="${workflow_info%%|*}"
      workflow_name="${workflow_info#*|}"

      echo "  Activating workflow: ${workflow_name} (${workflow_id})..."

      compose exec -T n8n \
        n8n publish:workflow \
        --id="$workflow_id"
    done

    echo "Restarting n8n to apply workflow changes and register webhooks..."

    compose restart n8n

    echo "Waiting for n8n to start..."

    for _ in {1..30}; do
      container_id="$(compose ps -q n8n)"

      if [[ -n "$container_id" ]] && \
         [[ "$(docker inspect -f '{{.State.Running}}' "$container_id")" == "true" ]]; then
        break
      fi

      sleep 2
    done

    container_id="$(compose ps -q n8n)"

    if [[ -z "$container_id" ]] || \
       [[ "$(docker inspect -f '{{.State.Running}}' "$container_id")" != "true" ]]; then
      echo "Error: n8n did not start successfully." >&2
      exit 1
    fi

    echo "n8n is running."
  fi
fi

echo
if [[ "$ACTIVATE" == true ]]; then
  echo "Workflows and credentials imported and activated successfully."
else
  echo "Workflows and credentials imported successfully."
  echo "Use --activate to activate the imported workflows."
fi

