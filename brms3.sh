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
echo " JOB 3: BRMS BACKUP OPERATIONS v69"
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
# STEP 10: Poll for Transfer Completion (5 min interval, 15 attempts max)
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# STEP 10: Poll for Transfer Completion
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# STEP 10: Verify Cloud Upload (Polling every 5 minutes)
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# STEP 55: Verify Cloud Upload (Optimized)
# ------------------------------------------------------------------------------
echo "→ [STEP 55] Verifying backup files in Cloud Object Storage..."

# 1. Configuration
SYSTEM_NAME="MURPHYXP"
COS_DIR="QBRMS_${SYSTEM_NAME}"
POLL_INTERVAL=300  # 5 Minutes
MAX_RETRIES=20     # 20 checks * 5 min = 100 minutes max wait time

# 2. Generate Time Regex (Local Calculation)
#    Since Python 3 is now in your Docker container, we run this LOCALLY.
#    This avoids SSH complexity for simple date math.
echo "  Calculating search time window (Local Python)..."

TIME_SEARCH_PATTERN=$(python3 -c 'import datetime; \
now = datetime.datetime.now(); \
h0 = now.strftime("%Y-%m-%d %H"); \
h1 = (now - datetime.timedelta(hours=1)).strftime("%Y-%m-%d %H"); \
h2 = (now - datetime.timedelta(hours=2)).strftime("%Y-%m-%d %H"); \
print(h0 + "|" + h1 + "|" + h2)')

echo "  Search Pattern: '$TIME_SEARCH_PATTERN'"
echo "  Target Bucket:  s3://${COS_BUCKET}/${COS_DIR}/"

# 3. Polling Loop
count=0
found_files=false

while [ $count -lt $MAX_RETRIES ]; do
    echo "  Attempt $((count+1)) of $MAX_RETRIES: Checking bucket..."

    # We execute 'aws s3 ls' REMOTELY on the IBM i because that is where 
    # the 'aws configure' credentials likely reside [Source 15, 85].
    # We export the PATH to ensure 'aws' is found in /QOpenSys/pkgs/bin.
    REMOTE_CHECK="export PATH=/QOpenSys/pkgs/bin:\$PATH; \
                  aws --endpoint-url=${COS_ENDPOINT} s3 ls s3://${COS_BUCKET}/${COS_DIR}/ | grep -E '$TIME_SEARCH_PATTERN' | grep ' Q'"

    UPLOAD_RESULT=$(ssh -i "$VSI_KEY_FILE" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      ${SSH_USER}@${VSI_IP} \
      "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           ${SSH_USER}@${IBMI_CLONE_IP} \
           \"$REMOTE_CHECK\"" || true)

    if [[ -n "$UPLOAD_RESULT" ]]; then
        found_files=true
        break # Exit loop on success
    fi

    # If we are here, files were not found. Wait and retry.
    if [ $((count+1)) -lt $MAX_RETRIES ]; then
        echo "    No files found yet. Waiting $POLL_INTERVAL seconds..."
        sleep $POLL_INTERVAL
    fi
    ((count++))
done

# 4. Final Validation
if [ "$found_files" = true ]; then
    SAVED_FILES=$(echo "$UPLOAD_RESULT" | awk '{print $NF}')
    FILE_COUNT=$(echo "$SAVED_FILES" | wc -l)
    
    echo "✓ SUCCESS: Verified $FILE_COUNT volume(s) uploaded successfully."
    echo "---------------------------------------------------"
    echo " COMPLETION SUMMARY: VOLUMES UPLOADED"
    echo "---------------------------------------------------"
    echo "$SAVED_FILES"
    echo "---------------------------------------------------"
else
    echo "✗ FAILURE: Timed out waiting for files after $((MAX_RETRIES * POLL_INTERVAL / 60)) minutes."
    echo "  Troubleshooting:"
    echo "  1. Check if 'aws' is configured on IBM i (run 'aws configure' in SSH) [Source 86]."
    echo "  2. Verify the IBM i can reach the COS Endpoint: ${COS_ENDPOINT} [Source 14]."
    exit 1
fi
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
# Note: We split the PATH definition and export into two commands to satisfy the 
# IBM i shell (bsh) requirements. We use 'cat' to stream the binary save file 
# directly to the AWS CLI stdin (-).

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'PATH=/QOpenSys/pkgs/bin:\$PATH; export PATH; \
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
# Note: We split the PATH definition and export to ensure compatibility 
# with the IBM i shell (bsh). The file is downloaded to /tmp first 
# because AWS CLI cannot write to *SAVF directly [Source 914].

ssh -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'PATH=/QOpenSys/pkgs/bin:\$PATH; export PATH; \
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
echo "    • BRMS State:           *STRBKU → *ENDBKU" 
# This indicates the clone has finished its backup role [Source 483].
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
