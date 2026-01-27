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

# IBM Cloud Authentication (for optional cleanup job)
readonly API_KEY="${IBMCLOUD_API_KEY}"
readonly REGION="us-south"

# BRMS Configuration
# Note: Ensure these QCLDC* groups exist. If using defaults, change to QCLDB*.
readonly CONTROL_GROUP_1="QCLDCUSR01"     # First backup control group
readonly CONTROL_GROUP_2="QCLDCGRP01"     # Second backup control group

# Cloud Object Storage Configuration
readonly COS_ENDPOINT="https://s3.direct.us-south.cloud-object-storage.appdomain.cloud"
readonly COS_BUCKET="murphy-bucket-pvs-backups"
readonly COS_FILE="clnhist.file"

# Save File Configuration
readonly SAVF_LIB="CLDSTGTMP"
readonly SAVF_NAME="CLNHIST"
readonly SAVF_PATH_QSYS="/QSYS.LIB/CLDSTGTMP.LIB/CLNHIST.FILE"
# Changed to uppercase to match IBM i standards [Source 4: 117]
readonly SAVF_PATH_IFS="/QSYS.LIB/CLDSTGTMP.LIB/CLNHIST.FILE" 

# Polling Configuration
readonly POLL_INTERVAL=300                # 5 minutes
readonly MAX_POLL_ATTEMPTS=15             # 24 attempts max

echo "Configuration loaded successfully."
echo "  Clone LPAR:  ${IBMI_CLONE_IP}"
echo "  Source LPAR: ${IBMI_SOURCE_IP}"
echo "  VSI Jump:    ${VSI_IP}"
echo ""

################################################################################
# OPTIONAL STAGE: TRIGGER CLEANUP JOB
################################################################################
echo "========================================================================"
echo " OPTIONAL STAGE: CHAIN TO PVS CLONE CLEANUP"
echo "========================================================================"
echo ""

# Check the environment variable set in Code Engine
if [[ "${RUN_CLEANUP_JOB:-No}" == "Yes" ]]; then
    echo "→ Proceed to Cleanup has been requested - triggering PVS-Clone-Cleanup..."

    echo "→ Authenticating to IBM Cloud (Region: ${REGION})..."
    ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1 || {
    echo "✗ ERROR: IBM Cloud login failed"
    exit 1
    }
    echo "✓ Authentication successful"

    # Ensure we target the correct resource group
    echo "  Targeting resource group: cloud-techsales..."
    ibmcloud target -g cloud-techsales || {
        echo "⚠ WARNING: Unable to target resource group"
    }

    # Ensure we target the correct Code Engine project
    echo "  Switching to Code Engine project: usnm-project..."
    ibmcloud ce project target --name usnm-project > /dev/null 2>&1 || {
        echo "⚠ WARNING: Unable to target Code Engine project 'usnm-project'"
    }

    echo "  Submitting Code Engine job: PVS-Clone-Cleanup..."

    # Submit the job and capture output in JSON format
    # Note: Using '|| true' to prevent this script from crashing if the submit fails
    RAW_SUBMISSION=$(ibmcloud ce jobrun submit \
        --job pvs-clone-cleanup \
        --output json 2>&1 || true)

    # Parse the new JobRun name using jq
    NEXT_RUN=$(echo "$RAW_SUBMISSION" | jq -r '.metadata.name // .name // empty' 2>/dev/null || true)

    if [[ -z "$NEXT_RUN" ]]; then
        echo "⚠ WARNING: Cleanup job submission did not return a jobrun name"
        echo ""
        echo "Raw output:"
        echo "$RAW_SUBMISSION"
    else
        echo "✓ PVS-Clone-Cleanup triggered successfully"
        echo "  Jobrun instance: ${NEXT_RUN}"
    fi
else
    # Logic when cleanup is NOT requested
    echo "→ Proceed to Cleanup not set - skipping PVS-Clone-Cleanup."
    echo "  The previous operations are complete."
fi

echo ""
echo "========================================================================"
echo " JOB COMPLETE"
echo "========================================================================"

# Allow logs to flush to the console
echo "Finalizing job logs..."
sleep 60

# Explicitly exit with 0 (Success)
exit 0
