FROM ubuntu:22.04
# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
# Python3 is needed for local datetime calculations in the verification script
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
COPY brms5.sh /workspace/brms5.sh

# Make script executable
RUN chmod +x /workspace/brms5.sh

# Set entrypoint
ENTRYPOINT ["/workspace/brms5.sh"]
