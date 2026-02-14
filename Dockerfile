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
    libcap-dev \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /build

# Default shell; build logic is orchestrated by mise tasks
ENTRYPOINT ["bash", "-lc"]
CMD ["echo codex-builder image ready"]
