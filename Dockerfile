FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
# ADDED: dos2unix (Required to fix Windows line endings)
# Source [1, 2] recommend python3 and awscli for Cloud Object Storage interactions.
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    openssh-client \
    ca-certificates \
    python3 \
    python3-pip \
    awscli \
    dos2unix \
    && rm -rf /var/lib/apt/lists/*

# Install IBM Cloud CLI
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | sh

# Install PowerVS plugin
RUN ibmcloud plugin install power-iaas -f

# Install Code Engine plugin
RUN ibmcloud plugin install code-engine -f

# Create workspace directory
WORKDIR /workspace

# --- FIX: COPY MUST HAPPEN BEFORE RUNNING COMMANDS ON THE FILE ---
# Copy BRMS script into the container
COPY brms3.sh /workspace/brms3.sh

# Fix line endings and make executable
# We do this AFTER copying the file
RUN dos2unix /workspace/brms3.sh && chmod +x /workspace/brms3.sh

# Set entrypoint
ENTRYPOINT ["/workspace/brms3.sh"]

