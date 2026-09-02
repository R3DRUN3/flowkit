#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CERT_HOSTNAME="${CERT_HOSTNAME:-flowkit.local}"
CERT_DAYS="${CERT_DAYS:-36500}" # ~100 years

# ---------------------------------------------------------------------------
# Determine repository root
#
# This script lives in:
#   <repo>/scripts/create-certs.sh
#
# Therefore the repository root is one directory above SCRIPT_DIR.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CERT_DIR="${REPO_ROOT}/certs"

# ---------------------------------------------------------------------------
# Determine LAN IP
#
# Usage:
#   ./scripts/create-certs.sh
#   ./scripts/create-certs.sh 192.168.0.13
#
# If no IP is provided, detect the source IP used for the default route.
# ---------------------------------------------------------------------------

LAN_IP="${1:-$(ip route get 1.1.1.1 | awk '
    {
        for (i = 1; i <= NF; i++) {
            if ($i == "src") {
                print $(i + 1)
                exit
            }
        }
    }
')}"

if [[ -z "${LAN_IP}" ]]; then
    echo "Error: could not determine LAN IP."
    echo
    echo "Usage:"
    echo "  $0 <LAN_IP>"
    exit 1
fi

echo "Repository : ${REPO_ROOT}"
echo "Hostname   : ${CERT_HOSTNAME}"
echo "LAN IP     : ${LAN_IP}"
echo "Cert dir   : ${CERT_DIR}"
echo "Valid for  : ${CERT_DAYS} days"

# ---------------------------------------------------------------------------
# Create certificate directory
# ---------------------------------------------------------------------------

mkdir -p "${CERT_DIR}"

# ---------------------------------------------------------------------------
# Generate self-signed TLS certificate
# ---------------------------------------------------------------------------

openssl req -x509 \
    -nodes \
    -days "${CERT_DAYS}" \
    -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "${CERT_DIR}/flowkit.key" \
    -out "${CERT_DIR}/flowkit.crt" \
    -subj "/CN=${CERT_HOSTNAME}" \
    -addext "subjectAltName=DNS:${CERT_HOSTNAME},DNS:localhost,IP:${LAN_IP}"

echo
echo "TLS certificate created:"
echo "  ${CERT_DIR}/flowkit.crt"
echo "  ${CERT_DIR}/flowkit.key"

# ---------------------------------------------------------------------------
# Update /etc/hosts
#
# Remove an existing entry for flowkit.local and add the current LAN IP.
# This avoids duplicate/stale entries if the machine's IP changes.
# ---------------------------------------------------------------------------

HOSTS_ENTRY="${LAN_IP} ${CERT_HOSTNAME}"

if grep -qE "(^|[[:space:]])${CERT_HOSTNAME}([[:space:]]|$)" /etc/hosts; then
    echo
    echo "Updating /etc/hosts..."
    sudo sed -i -E \
        "/(^|[[:space:]])${CERT_HOSTNAME}([[:space:]]|$)/d" \
        /etc/hosts
else
    echo
    echo "Adding to /etc/hosts..."
fi

echo "${HOSTS_ENTRY}" | sudo tee -a /etc/hosts > /dev/null

echo "  ${HOSTS_ENTRY}"

# ---------------------------------------------------------------------------
# Verify certificate
# ---------------------------------------------------------------------------

echo
echo "Certificate:"
openssl x509 \
    -in "${CERT_DIR}/flowkit.crt" \
    -noout \
    -subject \
    -dates \
    -ext subjectAltName

echo
echo "Done."

