#!/usr/bin/env bash

################################################################################
# IBMi SSH Connection Test Script
# Purpose: Establish double-hop SSH connection to IBMi LPAR via VSI jump host
# Dependencies: SSH keys stored as Code Engine secrets
################################################################################

# ------------------------------------------------------------------------------
# TIMESTAMP LOGGING SETUP
# ------------------------------------------------------------------------------
timestamp() {
    while IFS= read -r line; do
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done
}
exec > >(timestamp) 2>&1

# ------------------------------------------------------------------------------
# STRICT ERROR HANDLING
# ------------------------------------------------------------------------------
set -eu

################################################################################
# BANNER
################################################################################
echo ""
echo "========================================================================"
echo " IBMi SSH CONNECTION TEST"
echo " Purpose: Verify double-hop SSH connectivity to IBMi LPAR"
echo "========================================================================"
echo ""

################################################################################
# CONFIGURATION VARIABLES
################################################################################

# Network Configuration
readonly VSI_IP="52.118.255.179"          # Jump host with public IP
readonly IBMI_IP="192.168.0.33"          # IBMi LPAR on private network
readonly SSH_USER="murphy"                 # Username for both VSI and IBMi

echo "Configuration loaded successfully."
echo "  VSI Jump Host: ${VSI_IP}"
echo "  IBMi LPAR:     ${IBMI_IP}"
echo "  SSH User:      ${SSH_USER}"
echo ""

################################################################################
# STAGE 1: SSH KEY INSTALLATION
################################################################################
echo "========================================================================"
echo " STAGE 1: SSH KEY INSTALLATION"
echo "========================================================================"
echo ""

echo "→ Installing SSH keys from Code Engine secrets..."

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# ------------------------------------------------------------------------------
# VSI SSH Key (RSA)
# ------------------------------------------------------------------------------
VSI_KEY_FILE="$HOME/.ssh/id_rsa"

if [ -z "${id_rsa:-}" ]; then
  echo "✗ ERROR: id_rsa environment variable is not set"
  exit 1
fi

echo "$id_rsa" > "$VSI_KEY_FILE"
chmod 600 "$VSI_KEY_FILE"
echo "  ✓ VSI SSH key installed"

# ------------------------------------------------------------------------------
# IBMi SSH Key (ED25519)
# ------------------------------------------------------------------------------
IBMI_KEY_FILE="$HOME/.ssh/id_ed25519_vsi"

if [ -z "${id_ed25519_vsi:-}" ]; then
  echo "✗ ERROR: id_ed25519_vsi environment variable is not set"
  exit 1
fi

echo "$id_ed25519_vsi" > "$IBMI_KEY_FILE"
chmod 600 "$IBMI_KEY_FILE"
echo "  ✓ IBMi SSH key installed"

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 1 Complete: SSH keys installed and configured"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# STAGE 2: ESTABLISH SSH CONNECTION TO IBMi
################################################################################
echo "========================================================================"
echo " STAGE 2: CONNECT TO IBMi LPAR"
echo "========================================================================"
echo ""

echo "→ Establishing double-hop SSH connection..."
echo "  Route: Code Engine → VSI (${VSI_IP}) → IBMi (${IBMI_IP})"
echo ""

# ------------------------------------------------------------------------------
# Double-hop SSH connection
# ------------------------------------------------------------------------------
ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_IP} \
       'echo \"Successfully connected to IBMi LPAR at ${IBMI_IP}\"'" || {
    echo "✗ ERROR: SSH connection failed"
    exit 1
}

echo "✓ SSH connection successful"
echo ""

echo "------------------------------------------------------------------------"
echo " Stage 2 Complete: Connected to IBMi LPAR"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# COMPLETION SUMMARY
################################################################################
echo ""
echo "========================================================================"
echo " CONNECTION TEST COMPLETED SUCCESSFULLY"
echo "========================================================================"
echo ""
echo "  Status:           ✓ SUCCESS"
echo "  VSI Jump Host:    ${VSI_IP}"
echo "  IBMi LPAR:        ${IBMI_IP}"
echo "  SSH User:         ${SSH_USER}"
echo "  Connection Path:  Code Engine → VSI → IBMi"
echo ""
echo "  Ready for IBMi command execution"
echo ""
echo "========================================================================"
echo ""

exit 0

