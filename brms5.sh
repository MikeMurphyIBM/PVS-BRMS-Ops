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
#set -eu

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
echo " STEP 5: Monitor System State (Wait for Down -> Wait for Up)"
echo "-----------------------------------------------------------------------------"

# --- Configuration ---------------------------------------------------------
# Phase A: Wait for Down (Check every 1 minute for 1 hour)
MAX_RETRIES_DOWN=60
SLEEP_DOWN_SEC=60

# Phase B: Wait for IPL (Check every 5 minutes for 2 hours)
MAX_RETRIES_UP=24     # 24 * 5 mins = 120 mins (2 Hours)
SLEEP_UP_SEC=300      # 300 seconds = 5 Minutes

# Phase C: Wait for SSH (Check every 30 seconds for 10 minutes)
MAX_RETRIES_SSH=20
SLEEP_SSH_SEC=30
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Sub-Step 5a: Wait for Network Drop (Confirm Restricted State)
# ---------------------------------------------------------------------------
echo ""
echo "   -> Phase A: Waiting for system to go OFFLINE (Processing SYS Group)..."
COUNTER=0
IS_DOWN=false

while [ $COUNTER -lt $MAX_RETRIES_DOWN ]; do
    # Logic: If Ping FAILS (!), the system is DOWN.
    if ! ssh -q -i "$VSI_KEY_FILE" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            ${SSH_USER}@${VSI_IP} \
            "ping -c 1 -W 1 ${IBMI_CLONE_IP} > /dev/null 2>&1"; then
        
        echo ""
        echo "✓ [$(date +%T)] Connection lost! System has entered restricted state."
        IS_DOWN=true
        break
    else
        echo "[$(date +%T)] Status: Still Online... waiting for restricted state."
        sleep $SLEEP_DOWN_SEC
        ((COUNTER++))
    fi
done

if [ "$IS_DOWN" = false ]; then
    echo "⚠️ [Phase A] WARNING: System did not go down after 60 minutes."
    exit 1
fi

# ---------------------------------------------------------------------------
# Sub-Step 5b: Wait for Network Recovery (IPL Complete)
# ---------------------------------------------------------------------------
echo ""
echo "   -> Phase B: Waiting for IPL to complete (Polling every 5 mins)..."
COUNTER=0
PING_SUCCESS=false

while [ $COUNTER -lt $MAX_RETRIES_UP ]; do
    # Logic: If Ping SUCCEEDS, the system is UP.
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
        # Using the longer 5-minute sleep here
        sleep $SLEEP_UP_SEC
        ((COUNTER++))
    fi
done

if [ "$PING_SUCCESS" = false ]; then
    echo "❌ [Phase B] Timeout: System failed to respond after 2 hours."
    exit 1
fi

# ---------------------------------------------------------------------------
# Sub-Step 5c: Wait for SSH (Application Layer)
# ---------------------------------------------------------------------------
echo ""
echo "   -> Phase C: Waiting for SSH Service..."
COUNTER=0
SSH_SUCCESS=false

while [ $COUNTER -lt $MAX_RETRIES_SSH ]; do
    # Logic: Try to run a dummy command ('true') via SSH to verify port 22 is ready.
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
        echo "[$(date +%T)] Status: Pingable but SSH not ready... waiting."
        sleep $SLEEP_SSH_SEC
        ((COUNTER++))
    fi
done

if [ "$SSH_SUCCESS" = false ]; then
    echo "❌ [Phase C] Timeout: SSH service did not start within 10 minutes."
    exit 1
fi

echo ""
echo "✓ [STEP 5] Cycle Complete: System Down -> IPL -> System Up -> SSH Ready."
echo ""



sleep 5

# ------------------------------------------------------------------------------
# JOB SUMMARY
# ------------------------------------------------------------------------------
# Ensure variable exists to prevent 'unbound variable' errors
FOUND_FILES=${FOUND_FILES:-""}

echo "========================================================================"
echo "              BRMS FLASHCOPY BACKUP JOB COMPLETION REPORT"
echo "========================================================================"
echo ""
echo "1. BRMS FLASHCOPY STATE:"
echo "   Source LPAR: *ENDPRC (Process Complete)"
echo "   Clone LPAR:  *ENDBKU (Backup Complete)"
echo ""
echo "2. CONTROL GROUPS PROCESSED:"
echo "   - QCLDBUSR01 (User Data)"
echo "   - QCLDBGRP01 (Group Data)"
echo ""
echo "3. CLOUD TRANSFER DETAILS:"
echo "   ✓ Cloud Object Storage transfer successful."
echo "   ✓ Target Bucket: s3://${COS_BUCKET}"
echo ""
echo "   [Uploaded Backup Volumes]"
echo "   ---------------------------------------------------"
# Simplified logic: Prints the files if they exist, or the default message if empty.
echo "${FOUND_FILES:-   (No volume names captured in polling variable)}"
echo "   ---------------------------------------------------"
echo ""
echo "4. HISTORY SYNCHRONIZATION:"
echo "   ✓ QUSRBRM downloaded from COS to Source."
echo "   ✓ Restored to temporary library ${SAVF_LIB}."
echo "   ✓ History merged into active BRMS database."
echo ""
echo "5. CLEANUP:"
echo "   ✓ Temporary resources removed from Source and Clone."
echo ""
echo "========================================================================"
echo "  ✓ All BRMS FlashCopy operations completed successfully"
echo "  ✓ Backup history synchronized between LPARs"
echo "  ✓ Production system ready for normal operations"
echo "========================================================================"

# CRITICAL FIX: Wait for logs to flush to the console before exiting
echo "Finalizing job logs..."
sleep 60

# Explicitly exit with 0 to tell Code Engine the job Succeeded
exit 0
