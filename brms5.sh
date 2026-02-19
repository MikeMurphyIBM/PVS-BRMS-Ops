#!/usr/bin/env bash

################################################################################
# JOB 3: BRMS BACKUP OPERATIONS
# Purpose: Execute BRMS backups on clone LPAR and sync history to source LPAR
# Dependencies: IBM Cloud CLI, SSH access to both LPARs
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
echo " JOB 3: BRMS BACKUP OPERATIONS"
echo " Purpose: Execute cloud backups and synchronize BRMS history"
echo "========================================================================"
echo ""

################################################################################
# CONFIGURATION VARIABLES
################################################################################

# SSH Configuration
readonly VSI_IP="52.118.255.179"          # Jump host with public IP
readonly IBMI_SOURCE_IP="192.168.0.33"    # Source LPAR (production)
readonly IBMI_CLONE_IP="192.168.10.35"    # Clone LPAR (backup target)
readonly SSH_USER="murphy"                # Username for all systems

# BRMS Configuration
# Note: Ensure these QCLDC* groups exist. If using defaults, change to QCLDB*.
readonly CONTROL_GROUP_1="QCLDCUSR01"     # First backup control group
readonly CONTROL_GROUP_2="QCLDCGRP01"     # Second backup control group

# Cloud Object Storage Configuration
readonly COS_ENDPOINT="https://s3.direct.us-south.cloud-object-storage.appdomain.cloud"
readonly COS_BUCKET="murphy-bucket-pvs-backups"
readonly COS_FILE="clnhist.file"
readonly ACCESS_KEY="${COS_ACCESS_KEY}"
readonly SECRET_KEY="${COS_SECRET_KEY}"

# -- BRMS & Cloud Resource Settings --
readonly CLOUD_RESOURCE="COSBACKUPS"

# Save File Configuration
readonly SAVF_LIB="CLDSTGTMP"
readonly SAVF_NAME="CLNHIST"
readonly SAVF_PATH_QSYS="/QSYS.LIB/CLDSTGTMP.LIB/CLNHIST.FILE"
# Changed to uppercase to match IBM i standards [Source 4: 117]
readonly SAVF_PATH_IFS="/QSYS.LIB/CLDSTGTMP.LIB/CLNHIST.FILE" 

# Polling Configuration
readonly POLL_INTERVAL=300                # 5 minutes
readonly MAX_POLL_ATTEMPTS=15             # 15 attempts max

echo "Configuration loaded successfully."
echo "  Clone LPAR:  ${IBMI_CLONE_IP}"
echo "  Source LPAR: ${IBMI_SOURCE_IP}"
echo "  VSI Jump:    ${VSI_IP}"
echo ""


################################################################################
# STEP 1: SSH KEY INSTALLATION
################################################################################

echo "========================================================================"
echo " STEP 1: SSH KEY INSTALLATION"
echo "========================================================================"
echo ""

echo "→ Installing SSH keys from Code Engine secrets..."

# Ensure .ssh directory exists with correct permissions
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# --- VSI SSH Key Setup ---
VSI_KEY_FILE="$HOME/.ssh/id_rsa"

if [ -z "${id_rsa:-}" ]; then
  echo "✗ ERROR: id_rsa environment variable is not set"
  exit 1
fi

# Use printf to ensure newline characters in the key are preserved correctly
printf "%s\n" "$id_rsa" > "$VSI_KEY_FILE"
chmod 600 "$VSI_KEY_FILE"
echo "  ✓ VSI SSH key installed"

# --- IBMi SSH Key Setup ---
IBMI_KEY_FILE="$HOME/.ssh/id_ed25519_vsi"

if [ -z "${id_ed25519_vsi:-}" ]; then
  echo "✗ ERROR: id_ed25519_vsi environment variable is not set"
  exit 1
fi

printf "%s\n" "$id_ed25519_vsi" > "$IBMI_KEY_FILE"
chmod 600 "$IBMI_KEY_FILE"
echo "  ✓ IBMi SSH key installed"

# ------------------------------------------------------------------------------
# SSH Configuration
# ------------------------------------------------------------------------------
# Define common SSH options to prevent interactive prompts and timeouts

SSH_OPTS="-q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=60 -o ServerAliveCountMax=60"

echo ""
echo "------------------------------------------------------------------------"
echo " Step 1 Complete: SSH keys installed"
echo "------------------------------------------------------------------------"
echo ""

echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 5: Monitor System State"
echo "-----------------------------------------------------------------------------"

# --- Configuration (Standardized) --------------------------
# We use simple variable names to avoid mismatches
MAX_RETRIES=60       # 1 hour max wait for down
IPL_RETRIES=24       # 2 hours max wait for IPL (24 * 5m)
SSH_RETRIES=20       # 20 attempts for SSH

WAIT_SHORT=60        # 60 seconds (Standard wait)
WAIT_LONG=300        # 300 seconds (5 minutes for IPL)
# -----------------------------------------------------------

# Enable debug mode to show exact commands being executed
#set -x 

echo "   -> Phase A: Waiting for system to go OFFLINE..."
COUNTER=0
IS_DOWN=false

while [ $COUNTER -lt $MAX_RETRIES ]; do
    # Check if Ping FAILS (!). If it fails, system is DOWN.
    if ! ssh -q -i "$VSI_KEY_FILE" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            ${SSH_USER}@${VSI_IP} \
            "ping -c 1 -W 1 ${IBMI_CLONE_IP} > /dev/null 2>&1"; then
        
        echo ""
        echo "✓ [$(date +%T)] Connection lost! System is OFF-LINE."
        IS_DOWN=true
        break
    else
        echo "[$(date +%T)] Status: Still Online... waiting."
        # Using the standardized variable
        sleep $WAIT_SHORT
        # Safe increment (works in sh and bash)
        COUNTER=$((COUNTER + 1))
    fi
done

if [ "$IS_DOWN" = false ]; then
    echo "⚠️ [Phase A] WARNING: System did not go down after 60 minutes."
    # We exit here to prevent the job from hanging forever
    exit 1
fi

echo ""
echo "   -> Phase B: Waiting for IPL to complete..."

COUNTER=0
PING_SUCCESS=false

while [ $COUNTER -lt $IPL_RETRIES ]; do
    # Check if Ping SUCCEEDS.
    if ssh -q -i "$VSI_KEY_FILE" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            ${SSH_USER}@${VSI_IP} \
            "ping -c 1 -W 1 ${IBMI_CLONE_IP} > /dev/null 2>&1"; then
        
        echo ""
        echo "✓ [$(date +%T)] PING Successful! System is back online."
        PING_SUCCESS=true
        break
    else
        echo "[$(date +%T)] Status: Still Offline... IPL in progress."
        # Using the LONG wait variable (5 mins)
        sleep $WAIT_LONG
        COUNTER=$((COUNTER + 1))
    fi
done

if [ "$PING_SUCCESS" = false ]; then
    echo "❌ [Phase B] Timeout: System failed to respond after 2 hours."
    exit 1
fi

echo ""
echo "   -> Phase C: Waiting for SSH Service..."

COUNTER=0
SSH_SUCCESS=false

while [ $COUNTER -lt $SSH_RETRIES ]; do
    if ssh -q -i "$VSI_KEY_FILE" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            ${SSH_USER}@${VSI_IP} \
            "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
                 -o StrictHostKeyChecking=no \
                 -o UserKnownHostsFile=/dev/null \
                 -o ConnectTimeout=10 \
                 ${SSH_USER}@${IBMI_CLONE_IP} \
                 'true'"; then
        
        echo ""
        echo "✓ [$(date +%T)] SSH Successful! System is ready."
        SSH_SUCCESS=true
        break
    else
        echo "[$(date +%T)] Status: Pingable but SSH not ready..."
        sleep $WAIT_SHORT
        COUNTER=$((COUNTER + 1))
    fi
done

if [ "$SSH_SUCCESS" = false ]; then
    echo "❌ [Phase C] Timeout: SSH service did not start."
    exit 1
fi

# Disable debug mode
#set +x

echo "✓ [STEP 5] Complete."



sleep 5


# CRITICAL FIX: Wait for logs to flush to the console before exiting
echo "Finalizing job logs..."
sleep 60

# Explicitly exit with 0 to tell Code Engine the job Succeeded
exit 0
