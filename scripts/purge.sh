#!/usr/bin/env bash
#
# purge.sh
#
# FULL TEARDOWN of the Flowkit deployment. Brings the host back to
# approximately pre-Flowkit state: removes containers, images, volumes
# (n8n/Postgres/others - PERMANENT DATA LOSS), the 'flowkit' Linux
# user, its SSH keys, the sshd hardening drop-in, and locally generated
# secrets/backups.
#
# This is deliberately destructive and irreversible. It is NOT what you
# want for a routine stop - use stop.sh for that. Use this only when you
# are decommissioning the host or want to start completely clean.
#
# Usage:
#   ./scripts/purge.sh              # interactive, asks for confirmation
#   ./scripts/purge.sh --dry-run    # show what would be removed, do nothing
#   ./scripts/purge.sh --yes        # skip confirmation prompt (for CI/automation)
#   ./scripts/purge.sh --keep-backups   # don't delete ./backups
#
# Must be run as root (it deletes a Linux user and edits sshd config).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${REPO_ROOT}/compose/compose.yaml}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
FLOWKIT_USER="flowkit"
FLOWKIT_HOME="/home/${FLOWKIT_USER}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-flowkit.conf"
SECRETS_DIR="${REPO_ROOT}/secrets/flowkit"
BACKUPS_DIR="${REPO_ROOT}/backups"

DRY_RUN=0
ASSUME_YES=0
KEEP_BACKUPS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --keep-backups) KEEP_BACKUPS=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

if [[ "$EUID" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
  echo "This script must be run as root (it removes a system user and edits sshd config). Try: sudo $0" >&2
  exit 1
fi

echo "================================================================"
echo " Flowkit FULL PURGE"
echo "================================================================"
echo "This will PERMANENTLY remove:"
echo "  - All Flowkit containers (n8n, postgres, traefik)"
echo "  - The n8n_data, db_storage, traefik_data volumes (ALL WORKFLOWS,"
echo "    CREDENTIALS, AND EXECUTION HISTORY - unless backed up separately)"
echo "  - Docker images pulled for this stack"
echo "  - The Docker network created for this compose project"
echo "  - The '${FLOWKIT_USER}' Linux user, its home directory, and SSH keys"
echo "  - The sshd hardening drop-in for '${FLOWKIT_USER}'"
echo "  - Locally generated secrets at ${SECRETS_DIR}"
if [[ "$KEEP_BACKUPS" -eq 0 ]]; then
  echo "  - Local backups at ${BACKUPS_DIR} (pass --keep-backups to preserve them)"
else
  echo "  - (backups at ${BACKUPS_DIR} will be KEPT)"
fi
echo
echo "This does NOT touch: Docker Engine itself, other unrelated"
echo "containers/images on this host, or any off-host/remote backups."
echo "================================================================"

if [[ "$ASSUME_YES" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
  read -r -p "Type 'purge flowkit' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "purge flowkit" ]]; then
    echo "Aborted, nothing was changed."
    exit 0
  fi
fi

compose() {
  if [[ -f "$ENV_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
  else
    docker compose -f "$COMPOSE_FILE" "$@"
  fi
}

# ---------------------------------------------------------------------------
# 1. Tear down containers, volumes, and the compose network
# ---------------------------------------------------------------------------
echo
echo "--- Step 1: Removing containers, volumes, and network ---"
if [[ -f "$COMPOSE_FILE" ]]; then
  run compose down --volumes --remove-orphans
else
  echo "No compose file found at ${COMPOSE_FILE}, skipping compose down."
fi

# Belt-and-suspenders: explicitly remove the named volumes even if compose
# down --volumes didn't catch them (e.g. compose file was already deleted).
for vol in n8n_data db_storage traefik_data; do
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    run docker volume rm "$vol"
  fi
done

# ---------------------------------------------------------------------------
# 2. Remove images pulled for this stack
# ---------------------------------------------------------------------------
echo
echo "--- Step 2: Removing images ---"
for image in n8nio/n8n traefik postgres; do
  for img_id in $(docker images "$image" -q | sort -u); do
    run docker rmi -f "$img_id" || true
  done
done

# ---------------------------------------------------------------------------
# 3. Remove the flowkit Linux user, home dir, and SSH keys
# ---------------------------------------------------------------------------
echo
echo "--- Step 3: Removing '${FLOWKIT_USER}' user and SSH keys ---"
if id "$FLOWKIT_USER" &>/dev/null; then
  run pkill -u "$FLOWKIT_USER" 2>/dev/null || true
  run userdel -r "$FLOWKIT_USER" 2>/dev/null || run userdel -rf "$FLOWKIT_USER"
  echo "Removed user ${FLOWKIT_USER} and ${FLOWKIT_HOME}."
else
  echo "User ${FLOWKIT_USER} does not exist, skipping."
fi

# ---------------------------------------------------------------------------
# 4. Remove sshd hardening drop-in
# ---------------------------------------------------------------------------
echo
echo "--- Step 4: Removing sshd drop-in ---"
if [[ -f "$SSHD_DROPIN" ]]; then
  run rm -f "$SSHD_DROPIN"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if sshd -t 2>/dev/null; then
      systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || service ssh reload || true
      echo "Removed ${SSHD_DROPIN} and reloaded sshd."
    else
      echo "Warning: sshd -t failed after removing the drop-in. Check sshd config manually." >&2
    fi
  fi
else
  echo "No sshd drop-in found at ${SSHD_DROPIN}, skipping."
fi

# ---------------------------------------------------------------------------
# 5. Remove locally generated secrets and (optionally) backups
# ---------------------------------------------------------------------------
echo
echo "--- Step 5: Removing local secrets ---"
if [[ -d "$SECRETS_DIR" ]]; then
  run rm -rf "$SECRETS_DIR"
  echo "Removed ${SECRETS_DIR}."
else
  echo "No secrets directory at ${SECRETS_DIR}, skipping."
fi

if [[ "$KEEP_BACKUPS" -eq 0 ]]; then
  echo
  echo "--- Step 6: Removing local backups ---"
  if [[ -d "$BACKUPS_DIR" ]]; then
    run rm -rf "$BACKUPS_DIR"
    echo "Removed ${BACKUPS_DIR}."
  else
    echo "No backups directory at ${BACKUPS_DIR}, skipping."
  fi
else
  echo
  echo "--- Step 6: Skipped (--keep-backups) ---"
fi

echo
echo "================================================================"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete. Nothing was actually changed."
else
  echo "Purge complete. Host should now be back to pre-Flowkit state."
  echo "Note: Docker Engine itself and the 'docker' group are left in place,"
  echo "since other workloads on this host may depend on them."
fi
echo "================================================================"