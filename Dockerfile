FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    openssh-client \
    ca-certificates \
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
COPY brms.sh /workspace/brms.sh

# Make script executable
RUN chmod +x /workspace/brms.sh

# Set entrypoint
ENTRYPOINT ["/workspace/brms.sh"]
