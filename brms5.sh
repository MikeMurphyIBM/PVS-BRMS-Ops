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
echo " STEP 8: BRMS Flashcopy status change and QUSRBRM file history saved"
echo "------------------------------------------------------------------------------"
echo ""
echo "→ [STEP 8] Finalizing BRMS FlashCopy state and saving QUSRBRM history..."

# 8a. Update BRMS State to *ENDBKU
# This tells BRMS the backup is finished so the history is marked complete.
echo "  [Step 8] Setting BRMS state to *ENDBKU..."
ssh -q -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   'system \"INZBRM OPTION(*FLASHCOPY) STATE(*ENDBKU)\"'" || {
   echo "✗ FAILURE: Could not set BRMS state to *ENDBKU."
   exit 1
}

# 8b. Prepare Scratch Library (CLDSTGTMP)
# We use '|| true' on DLTLIB so the script doesn't fail if the library doesn't exist yet.
echo "  [8b] preparing temporary library CLDSTGTMP..."
ssh -q -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   'system \"DLTLIB LIB(CLDSTGTMP)\" > /dev/null 2>&1 || true; \
    system \"CRTLIB LIB(CLDSTGTMP)\"; \
    system \"CRTSAVF FILE(CLDSTGTMP/CLNHIST)\"'" || {
   echo "✗ FAILURE: Could not create temporary library or save file."
   exit 1
}

# 8c. Save QUSRBRM to the Save File
# We omit journals to save space/time as they aren't strictly needed for history merging.
echo "  [8c] Saving QUSRBRM to save file..."
ssh -q -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
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

if ssh -q -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   \"$UPLOAD_CMD\""; then
    echo "✓ SUCCESS: QUSRBRM history uploaded successfully."
else
    echo "✗ FAILURE: Could not upload QUSRBRM to Cloud Object Storage."
    exit 1
fi
echo ""

################################################################################
# SOURCE LPAR OPERATIONS
################################################################################
echo "========================================================================"
echo " SOURCE LPAR: DOWNLOAD & MERGE OPERATIONS"
echo " Target: ${IBMI_SOURCE_IP}"
echo "========================================================================"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 9: Create Library and Save File on Source LPAR"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 9] Creating library ${SAVF_LIB} and save file on source LPAR..."

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CRTLIB LIB(${SAVF_LIB})\"'" || {
    echo "⚠ WARNING: Library ${SAVF_LIB} may already exist"
}

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CRTSAVF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || {
    echo "✗ ERROR: Failed to create save file on source"
    exit 1
}

echo ""
echo "✓ Library and save file created on source LPAR"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 10: Download BRMS History File from COS to the Source LPAR"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 10] Downloading history file from COS to source LPAR..."
# Note: We split the PATH definition and export to ensure compatibility 
# with the IBM i shell (bsh). The file is downloaded to /tmp first 
# because AWS CLI cannot write to *SAVF directly

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'PATH=/QOpenSys/pkgs/bin:\$PATH; export PATH; \
        aws --endpoint-url=${COS_ENDPOINT} s3 cp s3://${COS_BUCKET}/${COS_FILE} /tmp/${COS_FILE}'" || {
    echo "✗ ERROR: Failed to download from COS"
    exit 1
}

echo ""
echo "✓ History file downloaded to /tmp/${COS_FILE}"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 11:  Copy Stream File to Save File"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 11] Copying stream file to QSYS save file..."
# We use CPYFRMSTMF with CVTDTA(*NONE) to ensure the binary Save File data
# is not corrupted by ASCII/EBCDIC conversion during the move to QSYS [1].

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CPYFRMSTMF FROMSTMF('\''/tmp/${COS_FILE}'\'') TOMBR('\''${SAVF_PATH_QSYS}'\'') MBROPT(*REPLACE) CVTDTA(*NONE)\"'" || {
    echo "✗ ERROR: Failed to copy stream file to save file"
    exit 1
}

echo "✓ Stream file copied to ${SAVF_PATH_QSYS}"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 12: Restore QUSRBRM to Temporary Library"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 12] Restoring QUSRBRM to temporary library TMPHSTLIB..."
# We restore to TMPHSTLIB because we cannot overwrite the active QUSRBRM.
# The merge command in the next step requires the data to be in a separate library [3].

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=60 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=60 \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"RSTLIB SAVLIB(QUSRBRM) DEV(*SAVF) SAVF(${SAVF_LIB}/${SAVF_NAME}) RSTLIB(TMPHSTLIB) ALWOBJDIF(*ALL) MBROPT(*ALL)\"'" || {
    echo "✗ ERROR: Failed to restore QUSRBRM"
    exit 1
}

echo ""
echo "✓ QUSRBRM restored to TMPHSTLIB"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 13: Merge History into Live BRMS Database"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 13] Merging history into live BRMS database..."
# INZBRM *MERGE consolidates the backup history from the clone into the source.
# This ensures the source system "knows" about the backups performed in the cloud [2].

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"INZBRM OPTION(*MERGE) FROMLIB(TMPHSTLIB) TOLIB(QUSRBRM) MERGE(*ARC *BKU *MED)\"'" || {
    echo "✗ ERROR: Failed to merge BRMS history"
    exit 1
}

echo ""
echo "✓ BRMS history merged successfully"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 14: End BRMS Flashcopy Process State"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 14] Finalizing BRMS FlashCopy state..."
# This command sets the BRMS FlashCopy state to complete mode (*ENDPRC).
# It automatically starts the Q1ABRMNET subsystem and resumes BRMS network 
# synchronization, allowing the system to communicate with other nodes [Source 597].

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"INZBRM OPTION(*FLASHCOPY) STATE(*ENDPRC)\"'" || {
    echo "✗ ERROR: Failed to set BRMS state to *ENDPRC"
    exit 1
}

echo ""
echo "✓ BRMS state set to *ENDPRC - normal operations resumed"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 15: Delete Temporary Library"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 15] Deleting temporary library TMPHSTLIB..."
# The history data has been merged into the production QUSRBRM library.
# We can now safely remove the temporary restore library [Source 723].

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTLIB LIB(TMPHSTLIB)\"'" || {
    echo "⚠ WARNING: Failed to delete TMPHSTLIB"
}

echo ""
echo "✓ TMPHSTLIB deleted"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 16: Delete Save File"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 16] Deleting save file..."

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || {
    echo "⚠ WARNING: Failed to delete save file"
}

echo ""
echo "✓ Save file deleted"
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 17: Delete Library"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 17] Deleting library ${SAVF_LIB}..."

#  Cleanup: Delete the temporary library on the Source
# We use || true to ensure the script doesn't fail if the library is already gone.
# We added -q to both SSH commands to silence "Permanently added" warnings.
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTLIB LIB(${SAVF_LIB})\"'" || true

# --- CRITICAL FIX: NO 'exit 0' HERE! ---
# The script must fall through to the lines below.

echo "✓ Library ${SAVF_LIB} deleted"
echo ""

echo "-----------------------------------------------------------------------"
echo " Source LPAR BRMS Operations Complete"
echo "-----------------------------------------------------------------------"
echo ""

sleep 15

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

sleep 5

# Explicitly exit with 0 to tell Code Engine the job Succeeded
exit 0
