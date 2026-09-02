#!/usr/bin/env bash
#
# export-workflows.sh
#
# Exports all workflows from the Flowkit n8n instance into ./workflows.
# Also exports all credentials referenced by those workflows into
# ./credentials/credentials.json.
#
# Credentials remain encrypted using N8N_ENCRYPTION_KEY.
#

set -euo pipefail


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/compose/compose.yaml}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
WORKFLOWS_DIR="${REPO_ROOT}/workflows"
CREDENTIALS_DIR="${REPO_ROOT}/credentials"
CREDENTIALS_FILE="${CREDENTIALS_DIR}/credentials.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env not found at ${ENV_FILE}." >&2
  echo "Copy .env.example to .env and fill in real values first." >&2
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: compose file not found at ${COMPOSE_FILE}." >&2
  exit 1
fi

mkdir -p "$WORKFLOWS_DIR" "$CREDENTIALS_DIR"

compose() {
  docker compose \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    "$@"
}

echo "Removing previous workflow exports..."
rm -f "${WORKFLOWS_DIR}"/*.json

echo "Exporting workflows..."

compose exec -T n8n \
  n8n export:workflow \
  --all \
  --separate \
  --pretty \
  --output=/backup/workflows

echo "Renaming workflow files..."

python3 - "$WORKFLOWS_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

directory = Path(sys.argv[1])

def safe_filename(name):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', name)
    name = re.sub(r'\s+', ' ', name).strip()
    return name or "unnamed-workflow"

for path in sorted(directory.glob("*.json")):
    with path.open("r", encoding="utf-8") as f:
        workflow = json.load(f)

    name = safe_filename(workflow.get("name", path.stem))
    destination = directory / f"{name}.json"

    if destination != path and destination.exists():
        raise SystemExit(
            f"Error: multiple workflows have the same name: {name!r}"
        )

    if destination != path:
        path.rename(destination)

print(f"Exported {len(list(directory.glob('*.json')))} workflow(s).")
PY

echo "Finding credentials referenced by workflows..."

mapfile -t CREDENTIAL_IDS < <(
  python3 - "$WORKFLOWS_DIR" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
credential_ids = set()

for path in directory.glob("*.json"):
    with path.open("r", encoding="utf-8") as f:
        workflow = json.load(f)

    for node in workflow.get("nodes", []):
        credentials = node.get("credentials", {})

        for credential in credentials.values():
            credential_id = credential.get("id")

            if credential_id:
                credential_ids.add(str(credential_id))

for credential_id in sorted(credential_ids):
    print(credential_id)
PY
)

rm -f "$CREDENTIALS_FILE"

if [[ ${#CREDENTIAL_IDS[@]} -eq 0 ]]; then
  echo "No credentials referenced by workflows."
  echo "Workflows exported successfully."
  exit 0
fi

echo "Exporting ${#CREDENTIAL_IDS[@]} referenced credential(s)..."

TEMP_CREDENTIALS_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_CREDENTIALS_DIR"
}
trap cleanup EXIT

for credential_id in "${CREDENTIAL_IDS[@]}"; do
  echo "  Exporting credential ${credential_id}..."

  compose exec -T n8n \
    n8n export:credentials \
    --id="$credential_id" \
    --output="/backup/credentials/.credential-${credential_id}.json"
done

echo "Combining credential exports..."

python3 - "$CREDENTIALS_DIR" "$CREDENTIALS_FILE" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
output = Path(sys.argv[2])

credentials = []

for path in sorted(directory.glob(".credential-*.json")):
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    if isinstance(data, list):
        credentials.extend(data)
    else:
        credentials.append(data)

with output.open("w", encoding="utf-8") as f:
    json.dump(credentials, f, indent=2)
    f.write("\n")

for path in directory.glob(".credential-*.json"):
    path.unlink()

print(f"Exported {len(credentials)} credential(s).")
PY

echo
echo "Backup completed successfully."
echo "  Workflows:   ${WORKFLOWS_DIR}"
echo "  Credentials: ${CREDENTIALS_FILE}"
