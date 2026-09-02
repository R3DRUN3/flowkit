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

if [[ -z "$SSH_HOST" ]]; then
  SSH_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
  SSH_HOST="${SSH_HOST:-127.0.0.1}"

  echo "No --ssh-host given, defaulting to detected host address: ${SSH_HOST}"
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
# 10. Final summary
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
echo "SSH host:"
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
echo "============================================================"

