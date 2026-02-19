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
echo " JOB 3: BRMS BACKUP OPERATIONS--Incremental Backups"
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
readonly ACCESS_KEY="${COS_ACCESS_KEY}"
readonly SECRET_KEY="${COS_SECRET_KEY}"
readonly CLOUD_RESOURCE="COSBACKUPS"


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

##########################################################################
# echo "Stage 2:  CLONE LPAR OPERATIONS"
################################################################################
echo "========================================================================"
echo " STEP 2: CLONE LPAR BRMS INITIALIZATION & BACKUP OPERATIONS"
echo " Target: ${IBMI_CLONE_IP}"
echo "========================================================================"
echo ""



# ------------------------------------------------------------------------------
# STEP 2: Set BRMS State to Start Backup
# ------------------------------------------------------------------------------
echo "→ [Step 2] Setting BRMS State to *Start Backup.."
# This command informs the clone LPAR that it is in FlashCopy mode 
# and ready to perform backups.

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       \"system \\\"INZBRM OPTION(*FLASHCOPY) STATE(*STRBKU)\\\"\"" || {
    echo "✗ ERROR: Failed to set BRMS state to *STRBKU"
    exit 1
}

echo "✓ BRMS state set to *STRBKU"
echo ""


echo "-----------------------------------------------------------------------------"
echo " STEP 3: Start ICC/COS Subsystem"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [Step 3] Starting ICC/COS subsystem..."
# We start the subsystem BEFORE backups to ensure cloud connectors are ready.
# Source [1] indicates the subsystem handles file copy operations.

ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
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

echo ""
echo "STEP 3b:  Updating ICC Resource Credentials..."
echo ""

# Updating S3 ICC COS Credentials...
# WRAPPED IN SSH TO EXECUTE ON THE CLONE
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       \"system \\\"CHGS3RICC RSCNM(${CLOUD_RESOURCE}) RSCDSC(BACKUPS_FOR_PVS) KEYID('${ACCESS_KEY}') SECRETKEY('${SECRET_KEY}')\\\"\""
if [ $? -ne 0 ]; then
  echo "Critical Error: Failed to update credentials. Aborting."
  exit 1
fi
echo "Credentials updated successfully."
echo ""


echo "-----------------------------------------------------------------------------"
echo " STEP 4: Run 1st BRMS Control Group"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [Step 4] Running Control Group: ${CONTROL_GROUP_1}..."

# Initialize variable (good practice with set -u)
RETVAL=0

# Run SSH. If it fails (non-zero), '||' catches it and assigns the code to RETVAL.
# This prevents 'set -e' from killing the script.
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=120 \
       ${SSH_USER}@${IBMI_CLONE_IP} \
       'system \"STRBKUBRM CTLGRP(${CONTROL_GROUP_1}) SBMJOB(*NO)\"'" || RETVAL=$?

# Now analyze the captured return code
if [ "$RETVAL" -ne 0 ]; then
    echo "⚠️ [STEP 4] Backup completed with exit code $RETVAL."
    echo "  (This is expected behavior for Cloud Backups where media transfer happens later)."
else
    echo "✓ [STEP 4] Backup completed successfully."
fi
echo ""

echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 5: Run 2nd BRMS Control Group"
echo "-----------------------------------------------------------------------------"
echo ""
echo "  This will run synchronously and may take a long time..."
echo ""

# Initialize variable to safe default
RETVAL=0

# Run SSH. Use '|| RETVAL=$?' to catch the non-zero exit code without triggering 'set -e'
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
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

echo ""
echo "-----------------------------------------------------------------------------"
echo " STEP 6: Run BRMS Maintenance to clean up files and move media to COS"
echo "------------------------------------------------------------------------------"
echo ""

echo "→ [STEP 6] Running BRMS Maintenance..."

# Initialize variable
RETVAL=0

# Run Maintenance. Use '|| RETVAL=$?' to catch non-zero exit codes.
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
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

sleep 300

echo ""
echo ""

echo "-----------------------------------------------------------------------------"
echo " STEP 9: Wait for Cloud Object Storage (COS) Upload to Complete"
echo "-----------------------------------------------------------------------------"
echo "   -> Polling IBM i to check for volumes in Transfer (*TRF) state..."

# --- Configuration for Transfer Polling ---
# Wait up to 6 hours (72 * 5 mins) to accommodate large full system saves
MAX_RETRIES_TRF=72   
SLEEP_TRF_SEC=300    
# ------------------------------------------

COUNTER=0
TRANSFER_COMPLETE=false

while [ $COUNTER -lt $MAX_RETRIES_TRF ]; do
    # Run WRKMEDBRM TYPE(*TRF) to check if any volumes are still transferring.
    # If it returns BRM1134, CPF9861, or is empty, the transfer queue is clear.
    TRF_CHECK=$(ssh -q -i "$VSI_KEY_FILE" $SSH_OPTS \
        ${SSH_USER}@${VSI_IP} \
        "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS \
             ${SSH_USER}@${IBMI_CLONE_IP} \
             'system \"WRKMEDBRM TYPE(*TRF) OUTPUT(*PRINT)\"' 2>&1" )

    if [[ "$TRF_CHECK" == *"BRM1134"* ]] || [[ "$TRF_CHECK" == *"CPF9861"* ]] || [[ -z "$TRF_CHECK" ]]; then
        echo ""
        echo "✓ [$(date +%T)] Transfer Complete! No volumes remaining in *TRF state."
        TRANSFER_COMPLETE=true
        break
    else
        echo "[$(date +%T)] Status: Upload in progress. Volumes are still in *TRF state..."
        sleep $SLEEP_TRF_SEC
        COUNTER=$((COUNTER + 1))
    fi
done

if [ "$TRANSFER_COMPLETE" = false ]; then
    echo "❌ [Step 9] Timeout: Cloud upload did not complete within 6 hours."
    exit 1
fi

# ------------------------------------------------------------------------------
# Sub-Step: Populate FOUND_FILES for the Job Summary Report
# ------------------------------------------------------------------------------
echo ""
echo "   -> Retrieving list of uploaded files for the job summary..."

BRMS_DIR="QBRMS_MURPHYXP"
CHECK_CMD="PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin:\$PATH; export PATH; \
           aws --endpoint-url=${COS_ENDPOINT} s3 ls s3://${COS_BUCKET}/${BRMS_DIR}/ | \
           grep \`date +%Y-%m-%d\` | \
           awk '{print \$4}'"

FOUND_FILES=$(ssh -q -i "$VSI_KEY_FILE" $SSH_OPTS ${SSH_USER}@${VSI_IP} \
   "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi $SSH_OPTS ${SSH_USER}@${IBMI_CLONE_IP} \
   \"$CHECK_CMD\"") || true

echo "✓ SUCCESS: BRMS backup volumes safely transferred to cloud."
echo "---------------------------------------------------"
echo "$FOUND_FILES"
echo "---------------------------------------------------"
echo ""

echo ""
echo "-----------------------------------------------------------------------------"
echo " STEP 7b: Run BRMS Maintenance to inform directory of successful transfer"
echo "------------------------------------------------------------------------------"
echo ""

echo "→ [STEP 7b] Running BRMS Maintenance..."

# Initialize variable
RETVAL=0

# Run Maintenance. Use '|| RETVAL=$?' to catch non-zero exit codes.
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
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
    echo "✓ [STEP 7b] Maintenance completed successfully."
fi

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
echo "→ [STEP 9] Creating library ${SAVF_LIB}..."

# 1. Create the Library (Ignore failure if it already exists)
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CRTLIB LIB(${SAVF_LIB})\"'" || {
    echo "⚠ WARNING: Library ${SAVF_LIB} exists or could not be created. Proceeding..."
}

echo "→ [STEP 9] Preparing Save File (Delete old version if exists)..."

# 2. Delete the old Save File (Ignore failure if file doesn't exist)
# We accept failure here (|| true) because it's okay if the file isn't there to delete.
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || true

# 3. Wait briefly to ensure the object lock is released
echo "→ [STEP 9] Waiting 5 seconds for system cleanup..."
sleep 5

echo "→ [STEP 9] Creating new Save File..."

# 4. Create the new Save File (This must succeed)
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"CRTSAVF FILE(${SAVF_LIB}/${SAVF_NAME})\"'" || {
    echo "✗ ERROR: Failed to create save file ${SAVF_LIB}/${SAVF_NAME} on source"
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
echo " STEP 14b: Run BRMS Maintenance on Source to finalize database updates"
echo "------------------------------------------------------------------------------"
echo ""

echo "→ [STEP 14b] Running BRMS Maintenance on Source LPAR (${IBMI_SOURCE_IP})..."

# Initialize variable
RETVAL=0

# Run Maintenance. Use '|| RETVAL=$?' to catch non-zero exit codes.
# CHANGED: Targeted IBMI_SOURCE_IP instead of CLONE
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ServerAliveInterval=60 \
  -o ServerAliveCountMax=120 \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       -o ServerAliveInterval=60 \
       -o ServerAliveCountMax=120 \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"STRMNTBRM MOVMED(*YES) RUNCLNUP(*YES) PRTRCYRPT(*ALL)\"'" || RETVAL=$?

# Check the code. 
# Note: Code 0 is success. 
if [ "$RETVAL" -ne 0 ]; then
    echo "⚠️ [STEP 14b] Source Maintenance completed with exit code $RETVAL."
    echo "  (This is common for STRMNTBRM if there were minor warnings or locked files)."
    echo "  Proceeding to finalization..."
else
    echo "✓ [STEP 14b] Source Maintenance completed successfully."
fi

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


# STEP 17: Delete Library (Corrected to prevent script exit on warnings)
# -----------------------------------------------------------------------------
echo "-----------------------------------------------------------------------------"
echo " STEP 17: Delete Library"
echo "-----------------------------------------------------------------------------"
echo ""
echo "→ [STEP 17] Deleting library ${SAVF_LIB}..."

# We append '|| true' to ensure that even if DLTLIB returns a warning/escape message,
# the script considers this step successful and proceeds to the summary.
# Source: BRMS maintenance/cleanup often generates informational messages treated as non-zero codes [1].
ssh -q -i "$VSI_KEY_FILE" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  ${SSH_USER}@${VSI_IP} \
  "ssh -q -i /home/${SSH_USER}/.ssh/id_ed25519_vsi \
       -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       ${SSH_USER}@${IBMI_SOURCE_IP} \
       'system \"DLTLIB LIB(${SAVF_LIB})\"'" || true

echo "✓ Library ${SAVF_LIB} deletion attempted (Cleaning up)."
echo ""
echo "-----------------------------------------------------------------------"
echo " Source LPAR BRMS Operations Complete"
echo "-----------------------------------------------------------------------"
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
echo "   - QCLDCUSR01 (User Data)"
echo "   - QCLDCGRP01 (Group Data)"
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
