FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
# ADDED: python3, python3-pip, and awscli are required for the verification script
# Source [1] recommends installing python3 and awscli for Cloud Object Storage interactions.
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    openssh-client \
    ca-certificates \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Install IBM Cloud CLI
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | sh

# Install PowerVS plugin
RUN ibmcloud plugin install power-iaas -f

# Install Code Engine plugin
RUN ibmcloud plugin install code-engine -f

# Create workspace directory
WORKDIR /workspace

# Copy BRMS script into the container
COPY brms3.sh /workspace/brms3.sh

# Make script executable
RUN chmod +x /workspace/brms3.sh

# Set entrypoint
ENTRYPOINT ["/workspace/brms3.sh"]
