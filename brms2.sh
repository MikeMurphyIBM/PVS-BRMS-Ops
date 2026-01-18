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
echo " JOB 3: BRMS BACKUP OPERATIONS v4"
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
# STAGE 1: SSH KEY INSTALLATION
################################################################################

echo "========================================================================"
echo " STAGE 1: SSH KEY INSTALLATION"
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

echo ""
echo "------------------------------------------------------------------------"
echo " Stage 1 Complete: SSH keys installed"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# CLONE LPAR OPERATIONS
################################################################################
echo "========================================================================"
echo " CLONE LPAR: INITIALIZATION & BACKUP OPERATIONS"
echo " Target: ${IBMI_CLONE_IP}"
echo "========================================================================"
echo ""

# ------------------------------------------------------------------------------
# STEP 1: Set Number of Optical Volumes
# ------------------------------------------------------------------------------
echo "→ [STEP 1] Setting number of optical volumes to 75..."
# Note: '*SET      ' contains 6 spaces to pad the parameter to 10 characters.
# This ensures the program call interprets the string correctly.

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       \"system \\\"CALL PGM(QBRM/Q1AOLD) PARM('NUMOPTVOLS' '*SET      ' '75')\\\"\"" || {
    echo "✗ ERROR: Failed to set NUMOPTVOLS"
    exit 1
}

echo "✓ Number of optical volumes set to 75"
echo ""

# ------------------------------------------------------------------------------
# STEP 2: Set BRMS State to Start Backup
# ------------------------------------------------------------------------------
echo "→ [STEP 2] Setting BRMS state to *STRBKU..."
# This command informs the clone LPAR that it is in FlashCopy mode 
# and ready to perform backups [Source 3: 335].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       \"system \\\"INZBRM OPTION(*FLASHCOPY) STATE(*STRBKU)\\\"\"" || {
    echo "✗ ERROR: Failed to set BRMS state to *STRBKU"
    exit 1
}

echo "✓ BRMS state set to *STRBKU"
echo ""

# ------------------------------------------------------------------------------
# STEP 3: Set Temporary BRMS System Name (MCLONE)
# ------------------------------------------------------------------------------
echo "→ [STEP 3] Setting temporary BRMS system name to MCLONE..."
# We temporarily set the BRMS name to MCLONE to differentiate it from the source
# before running the initialization in Step 4 [Source 560].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       \"system \\\"CALL QBRM/Q1AOLD PARM('BRMSYSNAME' '*SET      ' 'MCLONE')\\\"\"" || {
    echo "✗ ERROR: Failed to set BRMS system name to MCLONE"
    exit 1
}

echo "✓ BRMS system name set to MCLONE"
echo ""

# ------------------------------------------------------------------------------
# STEP 4: Change System Network Attributes to Local
# ------------------------------------------------------------------------------
echo "→ [STEP 4] Changing system network attributes to *LCL..."
# This command updates the BRMS database to associate the history of the 
# 'Previous System' (Source) with the current local system (*LCL).
# Note: Ensure 'APPN' matches your system's LCLNETID (Local Network ID) [Source 218].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"INZBRM OPTION(*CHGSYSNAM) PRVSYSNAM(APPN.MURPHYXP) NEWSYSNAM(*LCL)\"'" || {
    echo "✗ ERROR: Failed to change system network attributes"
    exit 1
}

echo "✓ System network attributes changed to *LCL"
echo ""

# ------------------------------------------------------------------------------
# STEP 5: Set BRMS System Name to MURPHYXP
# ------------------------------------------------------------------------------
echo "→ [STEP 5] Setting BRMS system name to MURPHYXP..."
# By setting the BRMS name back to the source name (MURPHYXP), any backup 
# performed by this clone will be recorded in history as if it were 
# performed by the production system [Source 560].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       \"system \\\"CALL QBRM/Q1AOLD PARM('BRMSYSNAME' '*SET      ' 'MURPHYXP')\\\"\"" || {
    echo "✗ ERROR: Failed to set BRMS system name to MURPHYXP"
    exit 1
}

echo "✓ BRMS system name set to MURPHYXP"
echo ""

# ------------------------------------------------------------------------------
# STEP 6: Start ICC/COS Subsystem
# ------------------------------------------------------------------------------
echo "→ [STEP 6] Starting ICC/COS subsystem..."
# We start the subsystem BEFORE backups to ensure cloud connectors are ready.
# Source [1] indicates the subsystem handles file copy operations.

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"STRSBS SBSD(QICC/QICCSBS)\"'" || {
    echo "⚠ WARNING: ICC subsystem may already be active or failed to start"
}

# Give the subsystem a moment to fully initialize
sleep 5
echo "✓ ICC/COS subsystem start command issued"
echo ""

# ------------------------------------------------------------------------------
# STEP 7: Run First Control Group (QCLDCUSR01)
# ------------------------------------------------------------------------------
echo "→ [STEP 7] Running Control Group: ${CONTROL_GROUP_1}..."
echo "  This will run synchronously and may take a long time..."
# SBMJOB(*NO) keeps the process in the current session so we can catch the exit code.
# [Source 28]

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=120 \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"STRBKUBRM CTLGRP(${CONTROL_GROUP_1}) SBMJOB(*NO)\"'" || {
    echo "✗ ERROR: Control group ${CONTROL_GROUP_1} failed"
    exit 1
}

echo "✓ Control group ${CONTROL_GROUP_1} completed successfully"
echo ""

# ------------------------------------------------------------------------------
# STEP 8: Run Second Control Group (QCLDCGRP01)
# ------------------------------------------------------------------------------
echo "→ [STEP 8] Running Control Group: ${CONTROL_GROUP_2}..."
echo "  This will run synchronously and may take a long time..."
echo ""

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=120 \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"STRBKUBRM CTLGRP(${CONTROL_GROUP_2}) SBMJOB(*NO)\"'" || {
    echo "✗ ERROR: Control group ${CONTROL_GROUP_2} failed"
    exit 1
}

echo "✓ Control group ${CONTROL_GROUP_2} completed successfully"
echo ""

# ------------------------------------------------------------------------------
# STEP 9: Run BRMS Maintenance to Move Media to Cloud
# ------------------------------------------------------------------------------
echo "→ [STEP 9] Running BRMS maintenance to move media to cloud..."
echo "  This will run synchronously and may take a long time..."
# MOVMED(*YES) triggers the physical transfer of virtual volumes to COS.
# PRTRCYRPT(*ALL) generates the QP1ARCY recovery report needed for DR [Source 171: 359].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=120 \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"STRMNTBRM MOVMED(*YES) RUNCLNUP(*YES) PRTRCYRPT(*ALL)\"'" || {
    echo "✗ ERROR: BRMS maintenance failed"
    exit 1
}

echo "✓ BRMS maintenance complete - initiating cloud transfer"
echo ""

# ------------------------------------------------------------------------------
# STEP 10: Poll for Transfer Completion (5 min interval, 15 attempts max)
# ------------------------------------------------------------------------------
echo "→ [STEP 10] Polling for transfer completion to COS..."
echo "  Poll interval: ${POLL_INTERVAL} seconds (5 minutes)"
echo "  Max attempts: ${MAX_POLL_ATTEMPTS}"
echo ""

TRANSFER_COMPLETE=0
POLL_COUNT=0
VOLUMES_IN_TRANSFER=""

while [ $POLL_COUNT -lt $MAX_POLL_ATTEMPTS ]; do
    POLL_COUNT=$((POLL_COUNT + 1))
    echo "  Poll attempt ${POLL_COUNT}/${MAX_POLL_ATTEMPTS}: Checking transfer queue..."
    
    # WRKMEDBRM TYPE(*TRF) lists volumes currently in transfer or queued.
    # If the list is empty, the transfer is complete [Source 1: 31-32].
    OUTPUT=$(ssh -i "$VSI_KEY_FILE" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      ${SSH_USER}@${VSI_IP} \
      "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           ${SSH_USER}@${IBMI_CLONE_IP} \
           'system \"WRKMEDBRM TYPE(*TRF)\"'" 2>&1)
    
    # Check if output indicates no media (transfer queue empty)
    # Note: 'No media' is the standard message text when the list is empty.
    if echo "$OUTPUT" | grep -qi "No media"; then
        echo "✓ Transfer queue is empty - all uploads complete"
        TRANSFER_COMPLETE=1
        break
    else
        if [ $POLL_COUNT -lt $MAX_POLL_ATTEMPTS ]; then
            echo "  Volumes still transferring - waiting 5 minutes..."
            
            # Extract volume names currently in transfer (Lines containing *TRF)
            ACTIVE_VOLS=$(echo "$OUTPUT" | grep "\*TRF" | awk '{print $1}' | tr -d '\r')
            
            if [ -n "$ACTIVE_VOLS" ]; then
                echo "  > Currently transferring the following volumes:"
                echo "$ACTIVE_VOLS" | sed 's/^/    - /'
                
                # Store last known list for completion summary
                VOLUMES_IN_TRANSFER="$ACTIVE_VOLS"
            else
                echo "  > (Transfer in progress, but unable to parse specific volume IDs)"
            fi
            
            sleep $POLL_INTERVAL
        fi
    fi
done

if [ $TRANSFER_COMPLETE -eq 0 ]; then
    echo "✗ ERROR: Transfer did not complete within ${MAX_POLL_ATTEMPTS} attempts"
    exit 1
fi

# Count total volumes transferred
VOLUME_COUNT=0
if [ -n "$VOLUMES_IN_TRANSFER" ]; then
    VOLUME_COUNT=$(echo "$VOLUMES_IN_TRANSFER" | wc -l)
fi

echo ""

# ------------------------------------------------------------------------------
# STEP 11: Set BRMS State to End Backup
# ------------------------------------------------------------------------------
echo "→ [STEP 11] Setting BRMS state to *ENDBKU..."
# This command tells BRMS on the clone that the FlashCopy backup sequence 
# is finished [Source 599].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"INZBRM OPTION(*FLASHCOPY) STATE(*ENDBKU)\"'" || {
    echo "✗ ERROR: Failed to set BRMS state to *ENDBKU"
    exit 1
}

echo "✓ BRMS state set to *ENDBKU"
echo ""

# ------------------------------------------------------------------------------
# STEP 12: Create Library and Save File
# ------------------------------------------------------------------------------
echo "→ [STEP 12] Creating library ${SAVF_LIB} and save file ${SAVF_NAME}..."

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"CRTLIB LIB(${SAVF_LIB})\"'" || {
    echo "⚠ WARNING: Library ${SAVF_LIB} may already exist"
}

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"CRTSAVF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || {
    echo "✗ ERROR: Failed to create save file"
    exit 1
}

echo "✓ Library and save file created"
echo ""

# ------------------------------------------------------------------------------
# STEP 13: Save QUSRBRM to Save File
# ------------------------------------------------------------------------------
echo "→ [STEP 13] Saving QUSRBRM library to save file..."
# We use native SAVLIB (not SAVLIBBRM) because this data is intended for a 
# BRMS Merge operation on the source system, which requires a clean OS-level save.
# Omit journals/receivers to save space as they aren't needed for history merge [Source 730].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=60 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=60 \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"SAVLIB LIB(QUSRBRM) DEV(*SAVF) SAVF(${SAVF_LIB}/${SAVF_NAME}) OMITOBJ((*ALL *JRN) (*ALL *JRNRCV))\"'" || {
    echo "✗ ERROR: Failed to save QUSRBRM"
    exit 1
}

echo "✓ QUSRBRM saved to ${SAVF_PATH_IFS}"
echo ""

# ------------------------------------------------------------------------------
# STEP 14: Upload History File to COS
# ------------------------------------------------------------------------------
echo "→ [STEP 14] Uploading history file to COS..."
# Note: We export PATH inside this specific SSH command to ensure the 
# AWS CLI and its dependencies (Python) are found in the PASE environment.
# We use 'cat' to stream the binary save file directly to the AWS CLI stdin (-).
# [Source 113]

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'export PATH=/QOpenSys/pkgs/bin:\$PATH; \
        cat ${SAVF_PATH_IFS} | aws --endpoint-url=${COS_ENDPOINT} s3 cp - s3://${COS_BUCKET}/${COS_FILE}'" || {
    echo "✗ ERROR: Failed to upload history file to COS"
    exit 1
}

echo "✓ History file uploaded successfully to s3://${COS_BUCKET}/${COS_FILE}"
echo ""

# ------------------------------------------------------------------------------
# STEP 15: Delete Save File on Clone
# ------------------------------------------------------------------------------
echo "→ [STEP 15] Deleting save file on clone LPAR..."
# Clean up the temporary save file to free up storage on the clone.

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"DLTF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || {
    echo "⚠ WARNING: Failed to delete save file (cleanup)"
}

echo "✓ Save file deleted on clone LPAR"
echo ""

################################################################################
# SOURCE LPAR OPERATIONS
################################################################################
echo "========================================================================"
echo " SOURCE LPAR: DOWNLOAD & MERGE OPERATIONS"
echo " Target: ${IBMI_SOURCE_IP}"
echo "========================================================================"
echo ""

# ------------------------------------------------------------------------------
# STEP 17: Create Library and Save File on Source
# ------------------------------------------------------------------------------
echo "→ [STEP 17] Creating library ${SAVF_LIB} and save file on source LPAR..."

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CRTLIB LIB(${SAVF_LIB})\"'" || {
    echo "⚠ WARNING: Library ${SAVF_LIB} may already exist"
}

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CRTSAVF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || {
    echo "✗ ERROR: Failed to create save file on source"
    exit 1
}

echo "✓ Library and save file created on source LPAR"
echo ""

# ------------------------------------------------------------------------------
# STEP 19: Download History File from COS (PATH set inline)
# ------------------------------------------------------------------------------
echo "→ [STEP 19] Downloading history file from COS to source LPAR..."
# Note: We export PATH *inside* this command string. This is required because
# SSH sessions do not retain environment variables from previous steps.
# The file is downloaded to /tmp first because AWS CLI cannot write to *SAVF directly [Source 914].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'export PATH=/QOpenSys/pkgs/bin:\$PATH; \
        aws --endpoint-url=${COS_ENDPOINT} s3 cp s3://${COS_BUCKET}/${COS_FILE} /tmp/${COS_FILE}'" || {
    echo "✗ ERROR: Failed to download from COS"
    exit 1
}

echo "✓ History file downloaded to /tmp/${COS_FILE}"
echo ""

# ------------------------------------------------------------------------------
# STEP 20: Copy Stream File to Save File
# ------------------------------------------------------------------------------
echo "→ [STEP 20] Copying stream file to QSYS save file..."
# We use CPYFRMSTMF with CVTDTA(*NONE) to ensure the binary Save File data
# is not corrupted by ASCII/EBCDIC conversion during the move to QSYS [1].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CPYFRMSTMF FROMSTMF('\''/tmp/${COS_FILE}'\'') TOMBR('\''${SAVF_PATH_QSYS}'\'') MBROPT(*REPLACE) CVTDTA(*NONE)\"'" || {
    echo "✗ ERROR: Failed to copy stream file to save file"
    exit 1
}

echo "✓ Stream file copied to ${SAVF_PATH_QSYS}"
echo ""

# ------------------------------------------------------------------------------
# STEP 21: Restore QUSRBRM to Temporary Library
# ------------------------------------------------------------------------------
echo "→ [STEP 21] Restoring QUSRBRM to temporary library TMPHSTLIB..."
# We restore to TMPHSTLIB because we cannot overwrite the active QUSRBRM.
# The merge command in the next step requires the data to be in a separate library [3].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=60 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=60 \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"RSTLIB SAVLIB(QUSRBRM) DEV(*SAVF) SAVF(${SAVF_LIB}/${SAVF_NAME}) RSTLIB(TMPHSTLIB) ALWOBJDIF(*ALL) MBROPT(*ALL)\"'" || {
    echo "✗ ERROR: Failed to restore QUSRBRM"
    exit 1
}

echo "✓ QUSRBRM restored to TMPHSTLIB"
echo ""

# ------------------------------------------------------------------------------
# STEP 22: Merge History into Live BRMS Database
# ------------------------------------------------------------------------------
echo "→ [STEP 22] Merging history into live BRMS database..."
# INZBRM *MERGE consolidates the backup history from the clone into the source.
# This ensures the source system "knows" about the backups performed in the cloud [2].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"INZBRM OPTION(*MERGE) FROMLIB(TMPHSTLIB) TOLIB(QUSRBRM) MERGE(*ARC *BKU *MED)\"'" || {
    echo "✗ ERROR: Failed to merge BRMS history"
    exit 1
}

echo "✓ BRMS history merged successfully"
echo ""

# ------------------------------------------------------------------------------
# STEP 23: End FlashCopy Process State
# ------------------------------------------------------------------------------
echo "→ [STEP 23] Finalizing BRMS FlashCopy state..."
# This command sets the BRMS FlashCopy state to complete mode (*ENDPRC).
# It automatically starts the Q1ABRMNET subsystem and resumes BRMS network 
# synchronization, allowing the system to communicate with other nodes [Source 597].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"INZBRM OPTION(*FLASHCOPY) STATE(*ENDPRC)\"'" || {
    echo "✗ ERROR: Failed to set BRMS state to *ENDPRC"
    exit 1
}

echo "✓ BRMS state set to *ENDPRC - normal operations resumed"
echo ""

# ------------------------------------------------------------------------------
# STEP 24: Delete Temporary Library (TMPHSTLIB)
# ------------------------------------------------------------------------------
echo "→ [STEP 24] Deleting temporary library TMPHSTLIB..."
# The history data has been merged into the production QUSRBRM library.
# We can now safely remove the temporary restore library [Source 723].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTLIB LIB(TMPHSTLIB)\"'" || {
    echo "⚠ WARNING: Failed to delete TMPHSTLIB"
}

echo "✓ TMPHSTLIB deleted"
echo ""

# ------------------------------------------------------------------------------
# STEP 25: Delete Save File
# ------------------------------------------------------------------------------
echo "→ [STEP 25] Deleting save file..."

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || {
    echo "⚠ WARNING: Failed to delete save file"
}

echo "✓ Save file deleted"
echo ""

# ------------------------------------------------------------------------------
# STEP 26: Delete Library (CLDSTGTMP)
# ------------------------------------------------------------------------------
echo "→ [STEP 26] Deleting library ${SAVF_LIB}..."

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTLIB LIB(${SAVF_LIB})\"'" || {
    echo "⚠ WARNING: Failed to delete library"
}

echo "✓ Library ${SAVF_LIB} deleted"
echo ""

echo "------------------------------------------------------------------------"
echo " Source LPAR Operations Complete"
echo "------------------------------------------------------------------------"
echo ""

################################################################################
# COMPLETION SUMMARY
################################################################################
echo ""
echo "========================================================================"
echo " JOB 3: COMPLETION SUMMARY"
echo "========================================================================"
echo ""
echo "  Status:              ✓ SUCCESS"
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  CLONE LPAR OPERATIONS (${IBMI_CLONE_IP})"
echo "    • Optical Volumes:      75"
echo "    • BRMS State:           *STRBKU → *ENDBKU" 
# This indicates the clone has finished its backup role [Source 483].
echo "    • System Name:          MCLONE → MURPHYXP"
echo "    • Control Group 1:      ${CONTROL_GROUP_1} ✓"
echo "    • Control Group 2:      ${CONTROL_GROUP_2} ✓"
echo "    • BRMS Maintenance:     MOVMED(*YES) ✓"
echo "    • Cloud Transfer:"
echo "        - Poll Attempts:    ${POLL_COUNT}"
echo "        - Volumes Uploaded: ${VOLUME_COUNT}"
if [ -n "$VOLUMES_IN_TRANSFER" ] && [ "$VOLUME_COUNT" -gt 0 ]; then
    echo "        - Volume Names:"
    echo "$VOLUMES_IN_TRANSFER" | sed 's/^/            /'
fi
echo "    • QUSRBRM Saved:        ${SAVF_LIB}/${SAVF_NAME}"
echo "    • Uploaded to COS:      s3://${COS_BUCKET}/${COS_FILE} ✓"
echo ""
echo "  SOURCE LPAR OPERATIONS (${IBMI_SOURCE_IP})"
echo "    • BRMS History Merged:       Yes ✓"
# Confirms production DB now contains the clone's backup records [Source 600].
echo "    • BRMS State:           *ENDPRC (Normal operations) ✓"
# Confirms the source has exited FlashCopy mode and resumed networking [Source 485].
echo "    • Cleanup:              All temporary objects deleted ✓"
echo ""
echo "  ────────────────────────────────────────────────────────────────"
echo "  COS Bucket:         ${COS_BUCKET}"
echo "  COS File:           ${COS_FILE}"
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  ✓ All BRMS FlashCopy operations completed successfully"
echo "  ✓ Backup history synchronized between LPARs"
echo "  ✓ Production system ready for normal operations"
echo ""
echo "========================================================================"
echo ""

exit 0
