FROM rust:1.93-bookworm

# Install all dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libssl-dev \
    pkg-config \
    curl \
    wget \
    git \
    jq \
    nodejs \
    npm \
    p7zip-full \
    dmg2img \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /build

# Copy the install script
COPY install-codex-linux.sh /usr/local/bin/install-codex.sh
RUN chmod +x /usr/local/bin/install-codex.sh

# Set environment
ENV WORKDIR=/build/codex-work
ENV INSTALL_DIR=/output
ENV HOME=/build

# Entrypoint runs the install script
ENTRYPOINT ["/usr/local/bin/install-codex.sh"]
