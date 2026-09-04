#!/usr/bin/env bash
#
# create-flowkit-user.sh
#
# Provisions the dedicated 'flowkit' Linux user used by n8n's SSH node
# to run Docker tooling on the host.
#
# Authentication:
#   - SSH password authentication: ENABLED
#   - SSH public-key authentication: DISABLED for this user
#   - Keyboard-interactive authentication: DISABLED
#
# Desktop login:
#   - flowkit is created as a system account
#   - AccountsService is configured to mark it as a system account
#   - GNOME/GDM therefore does not normally present flowkit as a desktop
#     login account
#
# Docker:
#   - flowkit is added to the docker group so it can run Docker commands
#     over SSH.
#
# SSH:
#   - sshd configuration is scoped to this user only via a Match User block
#   - the global sshd configuration is not modified
#
# Host addressing:
#   - By default this script no longer prints/recommends the host's LAN IP.
#   - Instead it defaults to "host.docker.internal", which is the portable
#     hostname n8n (running inside the Docker container) should use to reach
#     this host over SSH. This makes the resulting n8n SSH credential work
#     on ANY host, regardless of its actual IP address.
#   - On native Linux, "host.docker.internal" only resolves correctly if the
#     n8n container is started with:
#       extra_hosts:
#         - "host.docker.internal:host-gateway"
#     (this must be set in compose/compose.yaml on the n8n service).
#
# Usage:
#   sudo ./create-flowkit-user.sh [--ssh-host <hostname-or-ip>] [--ssh-port <port>]
#
# The script is safe to re-run:
#   - existing user is preserved
#   - existing password is preserved
#   - docker membership is preserved
#   - sshd drop-in is rewritten to the desired configuration
#   - no SSH private/public keys are generated
#
# IMPORTANT:
#   The flowkit password is intentionally NOT stored by this script.
#   On first creation, you will be prompted to set it.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

FLOWKIT_USER="flowkit"
FLOWKIT_HOME="/home/${FLOWKIT_USER}"

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-flowkit.conf"

# Default host value used for the printed n8n SSH credential instructions
# and for the sshd -T effective-config check. This has no effect on actual
# authentication (Match User is scoped by username, not by client address).
DEFAULT_SSH_HOST="host.docker.internal"

SSH_HOST=""
SSH_PORT="22"

# AccountsService configuration used by GNOME/GDM.
ACCOUNTS_SERVICE_DIR="/var/lib/AccountsService/users"
ACCOUNTS_SERVICE_FILE="${ACCOUNTS_SERVICE_DIR}/${FLOWKIT_USER}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-host)
      [[ $# -ge 2 ]] || {
        echo "Missing value for --ssh-host." >&2
        exit 1
      }
      SSH_HOST="$2"
      shift 2
      ;;

    --ssh-port)
      [[ $# -ge 2 ]] || {
        echo "Missing value for --ssh-port." >&2
        exit 1
      }
      SSH_PORT="$2"
      shift 2
      ;;

    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  echo "Try: sudo $0" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Determine SSH host
# ---------------------------------------------------------------------------
#
# Unlike earlier versions of this script, we do NOT default to the host's
# detected LAN IP anymore. That made the resulting n8n SSH credential
# host-specific and broke every time the stack was deployed on a different
# machine/network.
#
# Instead we default to "host.docker.internal", which Docker resolves (from
# inside the n8n container) to whatever host it is currently running on,
# as long as the n8n service in compose/compose.yaml has:
#
#   extra_hosts:
#     - "host.docker.internal:host-gateway"
#
# You can still override this with --ssh-host if you need to test against
# a concrete IP/hostname.
# ---------------------------------------------------------------------------

if [[ -z "$SSH_HOST" ]]; then
  SSH_HOST="$DEFAULT_SSH_HOST"

  echo "No --ssh-host given, defaulting to: ${SSH_HOST}"
  echo "(Make sure the n8n service has 'extra_hosts: [\"host.docker.internal:host-gateway\"]' in compose/compose.yaml)"
fi

# ---------------------------------------------------------------------------
# Required commands
# ---------------------------------------------------------------------------

command -v useradd >/dev/null || {
  echo "useradd not found." >&2
  exit 1
}

command -v usermod >/dev/null || {
  echo "usermod not found." >&2
  exit 1
}

command -v passwd >/dev/null || {
  echo "passwd not found." >&2
  exit 1
}

command -v sshd >/dev/null || {
  echo "sshd not found. Install openssh-server first." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Create the flowkit system user
# ---------------------------------------------------------------------------

if ! id "$FLOWKIT_USER" >/dev/null 2>&1; then

  useradd \
    --system \
    --create-home \
    --home-dir "$FLOWKIT_HOME" \
    --shell /bin/bash \
    --comment "n8n automation SSH-node user" \
    "$FLOWKIT_USER"

  echo "Created system user: ${FLOWKIT_USER}"

  USER_IS_NEW=1

else

  echo "User ${FLOWKIT_USER} already exists, skipping useradd."

  USER_IS_NEW=0

fi

# ---------------------------------------------------------------------------
# 2. Ensure the user has /bin/bash
#
# SSH commands executed by n8n need a normal shell.
# This does NOT grant GNOME desktop login.
# ---------------------------------------------------------------------------

CURRENT_SHELL="$(getent passwd "$FLOWKIT_USER" | cut -d: -f7)"

if [[ "$CURRENT_SHELL" != "/bin/bash" ]]; then

  usermod -s /bin/bash "$FLOWKIT_USER"

  echo "Set ${FLOWKIT_USER} login shell to /bin/bash."

else

  echo "${FLOWKIT_USER} already uses /bin/bash."

fi

# ---------------------------------------------------------------------------
# 3. Ensure docker group exists and add flowkit to it
# ---------------------------------------------------------------------------

if ! getent group docker >/dev/null 2>&1; then

  echo "Group 'docker' does not exist."

  echo "Docker does not appear to be installed/configured yet." >&2
  echo "Creating the group because flowkit requires Docker access."

  groupadd docker

else

  echo "Docker group already exists."

fi

if ! id -nG "$FLOWKIT_USER" | tr ' ' '\n' | grep -qx docker; then

  usermod -aG docker "$FLOWKIT_USER"

  echo "Added ${FLOWKIT_USER} to the docker group."

else

  echo "${FLOWKIT_USER} is already in the docker group."

fi

# ---------------------------------------------------------------------------
# 4. Set/enable the flowkit password
# ---------------------------------------------------------------------------
#
# Password authentication is intentionally enabled for SSH.
#
# On first creation, passwd prompts for the password.
#
# If the account already exists and its password is locked, unlock it first
# and then prompt for a new password.
#
# We never store the password in a file.
# ---------------------------------------------------------------------------

PASSWORD_STATUS="$(passwd -S "$FLOWKIT_USER" 2>/dev/null | awk '{print $2}')"

if [[ "$USER_IS_NEW" -eq 1 ]]; then

  echo
  echo "Set the SSH password for ${FLOWKIT_USER}."
  echo "This password is NOT stored by this script."
  echo

  passwd "$FLOWKIT_USER"

elif [[ "$PASSWORD_STATUS" == "L" || "$PASSWORD_STATUS" == "LK" ]]; then

  echo
  echo "The existing ${FLOWKIT_USER} password is locked."
  echo "A new password is required because SSH password authentication"
  echo "is being enabled."
  echo

  passwd "$FLOWKIT_USER"

else

  echo "Password for ${FLOWKIT_USER} is already enabled; preserving it."

fi

# ---------------------------------------------------------------------------
# 5. Configure AccountsService/GNOME so flowkit is treated as a system
#    account and does not normally appear on the GNOME/GDM login screen.
# ---------------------------------------------------------------------------

if [[ -d "/var/lib/AccountsService" ]]; then

  mkdir -p "$ACCOUNTS_SERVICE_DIR"

  cat > "$ACCOUNTS_SERVICE_FILE" <<EOF
[User]
SystemAccount=true
EOF

  chmod 644 "$ACCOUNTS_SERVICE_FILE"

  echo "Configured AccountsService: ${ACCOUNTS_SERVICE_FILE}"
  echo "Marked ${FLOWKIT_USER} as a system account for GNOME/GDM."

else

  echo "AccountsService directory not present; skipping GNOME/GDM account configuration."

fi

# ---------------------------------------------------------------------------
# 6. Configure sshd specifically for flowkit
# ---------------------------------------------------------------------------
#
# Password authentication:
#   YES
#
# Public-key authentication:
#   NO
#
# Keyboard-interactive:
#   NO
#
# AuthenticationMethods is deliberately omitted.
#
# Without AuthenticationMethods, successful completion of one enabled
# authentication method is sufficient.
#
# This Match User block affects only flowkit.
# ---------------------------------------------------------------------------

cat > "$SSHD_DROPIN" <<EOF
# Managed by create-flowkit-user.sh
# SSH access for the n8n automation user.
#
# This block applies ONLY to: ${FLOWKIT_USER}

Match User ${FLOWKIT_USER}
    PasswordAuthentication yes
    KbdInteractiveAuthentication no
    PubkeyAuthentication no
EOF

chmod 644 "$SSHD_DROPIN"

echo "Wrote sshd configuration: ${SSHD_DROPIN}"

# ---------------------------------------------------------------------------
# 7. Validate sshd configuration BEFORE reloading
# ---------------------------------------------------------------------------

if sshd -t 2>/dev/null; then

  echo "sshd configuration validated successfully."

else

  echo "ERROR: sshd configuration validation failed." >&2
  echo "The new ${SSHD_DROPIN} configuration will be removed." >&2

  rm -f "$SSHD_DROPIN"

  exit 1

fi

# ---------------------------------------------------------------------------
# 8. Reload SSH daemon
# ---------------------------------------------------------------------------

if systemctl reload sshd 2>/dev/null; then

  echo "Reloaded sshd."

elif systemctl reload ssh 2>/dev/null; then

  echo "Reloaded ssh."

elif service ssh reload 2>/dev/null; then

  echo "Reloaded ssh via service command."

else

  echo "ERROR: Could not reload SSH service." >&2
  exit 1

fi

# ---------------------------------------------------------------------------
# 9. Verify the effective sshd configuration for flowkit
# ---------------------------------------------------------------------------
#
# We use sshd -T -C so that the Match User block is actually evaluated.
#
# Note: "addr=127.0.0.1" below is only a placeholder value required by
# sshd -T -C syntax to evaluate Match blocks; it does not reflect (and does
# not need to reflect) the real client address that will connect from the
# n8n container via host.docker.internal.
# ---------------------------------------------------------------------------

echo
echo "Effective SSH authentication configuration for ${FLOWKIT_USER}:"

if sshd -T \
    -C "user=${FLOWKIT_USER},host=${SSH_HOST},addr=127.0.0.1" 2>/dev/null \
    | grep -E '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods) '; then

  true

else

  echo "Warning: could not display effective Match configuration." >&2

fi

# ---------------------------------------------------------------------------
# 10. Fix ownership of workflow/credential backup directories (if present)
# ---------------------------------------------------------------------------
#
# These directories are bind-mounted into the n8n container, which runs as
# uid/gid 1000 (the "node" user in the n8n image). Run this from the repo
# root so the relative paths resolve correctly.
# ---------------------------------------------------------------------------

for d in workflows credentials; do
  if [[ -d "$d" ]]; then
    chown -R 1000:1000 "$d"
    echo "Set ownership of ./${d} to 1000:1000."
  else
    echo "Directory ./${d} not found, skipping ownership fix (run from repo root if this is unexpected)."
  fi
done

# ---------------------------------------------------------------------------
# 11. Final summary
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo "flowkit user provisioning complete"
echo "============================================================"
echo
echo "User:"
echo "  ${FLOWKIT_USER}"
echo
echo "Home:"
echo "  ${FLOWKIT_HOME}"
echo
echo "Shell:"
echo "  /bin/bash"
echo
echo "Docker access:"
echo "  yes (${FLOWKIT_USER} is in the docker group)"
echo
echo "SSH password authentication:"
echo "  ENABLED"
echo
echo "SSH public-key authentication:"
echo "  DISABLED"
echo
echo "SSH keyboard-interactive authentication:"
echo "  DISABLED"
echo
echo "GNOME/GDM desktop account:"
echo "  hidden as a system account"
echo
echo "SSH host (for the n8n credential):"
echo "  ${SSH_HOST}:${SSH_PORT}"
echo
echo "sshd configuration:"
echo "  ${SSHD_DROPIN}"
echo
echo
echo "============================================================"
echo
echo "Configure the n8n SSH credential as:"
echo
echo "  Authentication: Password"
echo "  Host:           ${SSH_HOST}"
echo "  Port:           ${SSH_PORT}"
echo "  Username:       ${FLOWKIT_USER}"
echo "  Password:       <the password you configured>"
echo
echo "NOTE: For '${SSH_HOST}' to resolve from inside the n8n container on"
echo "native Linux, the n8n service in compose/compose.yaml must include:"
echo
echo "  extra_hosts:"
echo "    - \"host.docker.internal:host-gateway\""
echo
echo "============================================================"