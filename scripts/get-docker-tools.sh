#!/usr/bin/env bash
#
# get-docker-tools.sh
#
# Scans every workflow JSON file in ./workflows for SSH-node commands that
# invoke "docker run ...", extracts the referenced Docker image (with tag),
# and pulls each one locally.
#
# This lets you pre-seed the Flowkit host (or any Docker host) with every
# tool image referenced by the versioned workflows, without having to read
# through each workflow by hand.
#
# What it does:
#   1. Sanity-checks that the workflows directory exists.
#   2. Parses every *.json file in ./workflows and extracts the image
#      reference from any "docker run ... <image>" command found in
#      n8n-nodes-base.ssh / n8n-nodes-base.executeCommand node parameters.
#   3. Deduplicates the resulting image list.
#   4. Runs "docker pull" for each image, tag included.
#
# Usage:
#   ./scripts/get-docker-tools.sh
#   ./scripts/get-docker-tools.sh --dry-run   # list images, don't pull them
#
# Run from anywhere; paths below are relative to the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS_DIR="${WORKFLOWS_DIR:-${REPO_ROOT}/workflows}"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$WORKFLOWS_DIR" ]]; then
  echo "Error: workflows directory not found at ${WORKFLOWS_DIR}." >&2
  exit 1
fi

if ! compgen -G "${WORKFLOWS_DIR}/*.json" > /dev/null; then
  echo "No workflow JSON files found in ${WORKFLOWS_DIR}, nothing to do."
  exit 0
fi

echo "Scanning workflows in ${WORKFLOWS_DIR} for Docker images..."

# Extract every "docker run ... <image>" reference from the "command"
# parameter of SSH / Execute Command nodes across all workflow files.
mapfile -t IMAGES < <(
  python3 - "$WORKFLOWS_DIR" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

directory = Path(sys.argv[1])

# Node types whose "command" parameter may contain a shell command.
COMMAND_NODE_TYPES = {
    "n8n-nodes-base.ssh",
    "n8n-nodes-base.executeCommand",
}

# "docker run" flags that take a separate value argument (space-separated),
# so that value must be skipped rather than mistaken for the image name.
FLAGS_WITH_VALUE = {
    "-v", "--volume", "-e", "--env", "--env-file", "-p", "-P", "--publish",
    "-w", "--workdir", "-u", "--user", "--name", "--network", "--entrypoint",
    "--mount", "-l", "--label", "--memory", "-m", "--cpus", "--restart",
    "--add-host", "--dns", "--hostname", "-h",
    "--cpuset-cpus", "--gpus", "--pull", "--platform", "--log-driver",
    "--security-opt", "--cap-add", "--cap-drop", "--device", "--tmpfs",
    "--health-cmd", "--stop-signal",
}

IMAGE_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._\-/:@]*$")


def extract_image(command):
    """Return the Docker image reference from a shell command string that
    contains a `docker run ...` invocation, or None if it can't be found."""
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None

    for i, token in enumerate(tokens):
        if token != "run":
            continue
        if i == 0 or tokens[i - 1] != "docker":
            continue

        # Walk the tokens after "docker run", skipping flags (and their
        # values, for flags known to take one) until we hit the image name.
        j = i + 1
        while j < len(tokens):
            tok = tokens[j]
            if tok.startswith("-"):
                if "=" not in tok and tok in FLAGS_WITH_VALUE:
                    j += 2
                else:
                    j += 1
                continue
            if IMAGE_RE.match(tok):
                return tok
            return None
    return None


images = set()

for path in sorted(directory.glob("*.json")):
    try:
        with path.open("r", encoding="utf-8") as f:
            workflow = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        print(f"Warning: skipping {path.name} ({exc})", file=sys.stderr)
        continue

    for node in workflow.get("nodes", []):
        if node.get("type") not in COMMAND_NODE_TYPES:
            continue
        command = node.get("parameters", {}).get("command", "")
        if not command or "docker run" not in command:
            continue
        image = extract_image(command)
        if image:
            images.add(image)

for image in sorted(images):
    print(image)
PY
)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  echo "No 'docker run' commands found in any workflow, nothing to pull."
  exit 0
fi

echo "Found ${#IMAGES[@]} unique image(s):"
for image in "${IMAGES[@]}"; do
  echo "  - ${image}"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: skipping docker pull."
  exit 0
fi

echo
echo "Pulling images..."
FAILED=()
for image in "${IMAGES[@]}"; do
  echo "Pulling ${image}..."
  if ! docker pull "$image"; then
    FAILED+=("$image")
  fi
done

echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "All ${#IMAGES[@]} image(s) pulled successfully."
else
  echo "Warning: failed to pull ${#FAILED[@]} image(s):" >&2
  for image in "${FAILED[@]}"; do
    echo "  - ${image}" >&2
  done
  exit 1
fi