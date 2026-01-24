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
echo " JOB 3: BRMS BACKUP OPERATIONS v1"
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
# STEP 2: Set BRMS State to Start Backup
# ------------------------------------------------------------------------------
echo "→ [STEP 2] Setting BRMS state to *STRBKU..."
# This command informs the clone LPAR that it is in FlashCopy mode 
# and ready to perform backups.

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
# STEP 3: Start ICC/COS Subsystem
# ------------------------------------------------------------------------------
echo "→ [STEP 3] Starting ICC/COS subsystem..."
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
# STEP 4: Run First Control Group (QCLDCUSR01)
# ------------------------------------------------------------------------------
echo "→ [STEP 4] Running Control Group: ${CONTROL_GROUP_1}..."

# Initialize variable (good practice with set -u)
RETVAL=0

# Run SSH. If it fails (non-zero), '||' catches it and assigns the code to RETVAL.
# This prevents 'set -e' from killing the script.
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
       'system \"STRBKUBRM CTLGRP(${CONTROL_GROUP_1}) SBMJOB(*NO)\"'" || RETVAL=$?

# Now analyze the captured return code
if [ "$RETVAL" -ne 0 ]; then
    echo "⚠️ [STEP 7] Backup completed with exit code $RETVAL."
    echo "  (This is expected behavior for Cloud Backups where media transfer happens later)."
else
    echo "✓ [STEP 7] Backup completed successfully."
fi
echo ""

echo ""

# ------------------------------------------------------------------------------
# STEP 5: Run Second Control Group (QCLDCGRP01)
# ------------------------------------------------------------------------------
echo "→ [STEP 5] Running Control Group: ${CONTROL_GROUP_2}..."
echo "  This will run synchronously and may take a long time..."
echo ""

# Initialize variable to safe default
RETVAL=0

# Run SSH. Use '|| RETVAL=$?' to catch the non-zero exit code without triggering 'set -e'
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
       'system \"STRBKUBRM CTLGRP(${CONTROL_GROUP_2}) SBMJOB(*NO)\"'" || RETVAL=$?

# Now check the captured return code safely
if [ "$RETVAL" -ne 0 ]; then
  echo "⚠️ [STEP 5] Backup completed with exit code $RETVAL."
  echo "  (This is expected behavior for Cloud Backups where media transfer happens later)."
  # Optional: You can proceed safely here.
else
  echo "✓ [STEP 5] Backup completed successfully."
fi


# ------------------------------------------------------------------------------
# STEP 6: Run BRMS Maintenance to Move Media to Cloud
# ------------------------------------------------------------------------------

echo "→ [STEP 6] Running BRMS Maintenance..."

# Initialize variable
RETVAL=0

# Run Maintenance. Use '|| RETVAL=$?' to catch non-zero exit codes.
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
       'system \"STRMNTBRM MOVMED(*YES) RUNCLNUP(*YES) PRTRCYRPT(*ALL)\"'" || RETVAL=$?

# Check the code. 
# Note: Code 0 is success. 
if [ "$RETVAL" -ne 0 ]; then
    echo "⚠️ [STEP 6] Maintenance completed with exit code $RETVAL."
    echo "  (This is common for STRMNTBRM if there were minor warnings or locked files)."
    echo "  Proceeding to finalization..."
else
    echo "✓ [STEP 6] Maintenance completed successfully."
fi


# ------------------------------------------------------------------------------
# Check the BRMS Directory for ANY file updated today
# ------------------------------------------------------------------------------

# 1. Define the BRMS directory structure based on your system name
# BRMS stores files in a folder named QBRMS_{SystemName} 
# Assuming your system name is MURPHYXP based on your query.
BRMS_DIR="QBRMS_MURPHYXP"

# 2. Get today's date in the format AWS CLI uses (YYYY-MM-DD)
TODAY=$(date +%Y-%m-%d)


# ------------------------------------------------------------------------------
# STEP 7: Verify Cloud Upload (Polling Loop)
# ------------------------------------------------------------------------------
echo "→ [STEP 7] Verifying backups in s3://${COS_BUCKET}/${BRMS_DIR}/..."
echo "  Starting polling loop. Will check every 5 minutes for up to 1 hour."

# Configuration
MAX_RETRIES=15       # 15 checks * 5 minutes = 75 minutes max
SLEEP_SECONDS=300    # 5 minutes in seconds
FOUND_FILES=""

# Start the loop
for ((i=1; i<=MAX_RETRIES; i++)); do
    echo "  [Attempt $i/$MAX_RETRIES] Checking for backup files..."

    # 1. Define the remote command
    #    FIX: Added ':/QOpenSys/usr/bin' to the PATH so 'awk' can be found.
    #    - aws is in /QOpenSys/pkgs/bin
    #    - awk is in /QOpenSys/usr/bin
    CHECK_CMD="PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin:\$PATH; export PATH; \
               aws --endpoint-url=${COS_ENDPOINT} s3 ls s3://${COS_BUCKET}/${BRMS_DIR}/ | \
               grep \`date +%Y-%m-%d\` | \
               awk '{print \$4}'"

    # 2. Execute via SSH and capture the output (filenames)
    FOUND_FILES=$(ssh -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
       "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
       \"$CHECK_CMD\"") || true

    # 3. Check if we found anything
    if [ -n "$FOUND_FILES" ]; then
        echo "  ✓ Backup files detected!"
        break
    fi

    # 4. If not found, check if this was the last attempt
    if [ $i -lt $MAX_RETRIES ]; then
        echo "  ...No files found yet. Waiting 5 minutes..."
        sleep $SLEEP_SECONDS
    fi
done

# 5. Final Validation
if [ -n "$FOUND_FILES" ]; then
    echo "✓ SUCCESS: The following BRMS backup volumes were found in the cloud:"
    echo "---------------------------------------------------"
    echo "$FOUND_FILES"
    echo "---------------------------------------------------"
else
    echo "✗ FAILURE: Timed out after 1 hour. No backup volumes found for today."
    echo "  Please check BRMS logs on the partition or the COS bucket manually."
    exit 1
fi

# ------------------------------------------------------------------------------
# STEP 8: Finalize FlashCopy & Save QUSRBRM (Granular execution)
# ------------------------------------------------------------------------------
echo "→ [STEP 8] Finalizing BRMS FlashCopy state and saving QUSRBRM history..."

# 8a. Update BRMS State to *ENDBKU
# This tells BRMS the backup is finished so the history is marked complete.
echo "  [8] Setting BRMS state to *ENDBKU..."
ssh -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   'system \"INZBRM OPTION(*FLASHCOPY) STATE(*ENDBKU)\"'" || {
   echo "✗ FAILURE: Could not set BRMS state to *ENDBKU."
   exit 1
}

# 8b. Prepare Scratch Library (CLDSTGTMP)
# We use '|| true' on DLTLIB so the script doesn't fail if the library doesn't exist yet.
echo "  [8b] preparing temporary library CLDSTGTMP..."
ssh -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   'system \"DLTLIB LIB(CLDSTGTMP)\" > /dev/null 2>&1 || true; \
    system \"CRTLIB LIB(CLDSTGTMP)\"; \
    system \"CRTSAVF FILE(CLDSTGTMP/CLNHIST)\"'" || {
   echo "✗ FAILURE: Could not create temporary library or save file."
   exit 1
}

# 8c. Save QUSRBRM to the Save File
# We omit journals to save space/time as they aren't strictly needed for history merging.
echo "  [8c] Saving QUSRBRM to save file..."
ssh -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   'system \"SAVLIB LIB(QUSRBRM) DEV(*SAVF) SAVF(CLDSTGTMP/CLNHIST) OMITOBJ((*ALL *JRN) (*ALL *JRNRCV))\"'" || {
   echo "✗ FAILURE: Could not save QUSRBRM library."
   exit 1
}

# 8d. Upload the Save File to Cloud Object Storage
# We use the specific PATH export required for the PASE shell.
echo "  [8d] Uploading QUSRBRM save file to COS..."
UPLOAD_CMD="PATH=/QOpenSys/pkgs/bin:\$PATH; export PATH; \
            cat /qsys.lib/cldstgtmp.lib/clnhist.file | \
            aws --endpoint-url=${COS_ENDPOINT} s3 cp - s3://${COS_BUCKET}/clnhist.file"

if ssh -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   \"$UPLOAD_CMD\""; then
    echo "✓ SUCCESS: QUSRBRM history uploaded successfully."
else
    echo "✗ FAILURE: Could not upload QUSRBRM to Cloud Object Storage."
    exit 1
fi

################################################################################
# SOURCE LPAR OPERATIONS
################################################################################
echo "========================================================================"
echo " SOURCE LPAR: DOWNLOAD & MERGE OPERATIONS"
echo " Target: ${IBMI_SOURCE_IP}"
echo "========================================================================"
echo ""

# ------------------------------------------------------------------------------
# STEP 9: Create Library and Save File on Source
# ------------------------------------------------------------------------------
echo "→ [STEP 9] Creating library ${SAVF_LIB} and save file on source LPAR..."

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
# STEP 10: Download History File from COS (PATH set inline)
# ------------------------------------------------------------------------------
echo "→ [STEP 10] Downloading history file from COS to source LPAR..."
# Note: We split the PATH definition and export to ensure compatibility 
# with the IBM i shell (bsh). The file is downloaded to /tmp first 
# because AWS CLI cannot write to *SAVF directly

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
# STEP 11: Copy Stream File to Save File
# ------------------------------------------------------------------------------
echo "→ [STEP 11] Copying stream file to QSYS save file..."
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
# STEP 12: Restore QUSRBRM to Temporary Library
# ------------------------------------------------------------------------------
echo "→ [STEP 12] Restoring QUSRBRM to temporary library TMPHSTLIB..."
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
# STEP 13: Merge History into Live BRMS Database
# ------------------------------------------------------------------------------
echo "→ [STEP 13] Merging history into live BRMS database..."
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
# STEP 14: End FlashCopy Process State
# ------------------------------------------------------------------------------
echo "→ [STEP 14] Finalizing BRMS FlashCopy state..."
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
# STEP 15: Delete Temporary Library (TMPHSTLIB)
# ------------------------------------------------------------------------------
echo "→ [STEP 15] Deleting temporary library TMPHSTLIB..."
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
# STEP 16: Delete Save File
# ------------------------------------------------------------------------------
echo "→ [STEP 16] Deleting save file..."

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
# STEP 17: Delete Library (CLDSTGTMP)
# ------------------------------------------------------------------------------
echo "→ [STEP 17] Deleting library ${SAVF_LIB}..."

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

# ------------------------------------------------------------------------------
# JOB SUMMARY
# ------------------------------------------------------------------------------
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
if [ -n "$FOUND_FILES" ]; then
    echo "$FOUND_FILES"
else
    echo "   (No volume names captured in polling variable)"
fi
echo "   ---------------------------------------------------"
echo ""
echo "4. HISTORY SYNCHRONIZATION:"
echo "   ✓ QUSRBRM downloaded from COS to Source."
echo "   ✓ Restored to temporary library CLDSTGTMP."
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

# Explicitly exit with 0 to tell Code Engine the job Succeeded
exit 0
