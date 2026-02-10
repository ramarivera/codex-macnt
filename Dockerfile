FROM rust:1.93-bookworm

# Install all dependencies
RUN apt-get update && apt-get install -y \
    p7zip-full \
    build-essential \
    libssl-dev \
    pkg-config \
    curl \
    wget \
    git \
    jq \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install asar globally
RUN npm install -g asar

# Create working directory
WORKDIR /build

# Copy the install script into container
COPY install-codex-linux.sh /usr/local/bin/install-codex.sh
RUN chmod +x /usr/local/bin/install-codex.sh

# Set environment
ENV WORKDIR=/build/codex-work
ENV INSTALL_DIR=/output
ENV HOME=/build

# Entrypoint runs the install script
ENTRYPOINT ["/usr/local/bin/install-codex.sh"]
