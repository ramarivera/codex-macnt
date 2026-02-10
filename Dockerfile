# Dockerfile for building Codex Linux from macOS DMG
# Usage:
#   docker build -t codex-builder .
#   docker run --rm -v $(pwd)/output:/output codex-builder

FROM rust:1.93-bookworm

# Install all system dependencies
RUN apt-get update && apt-get install -y \
    p7zip-full \
    p7zip-rar \
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

# Set working directory
WORKDIR /build

# Download URLs
ENV CODEX_VERSION=260208.1016
ENV CODEX_DMG_URL=https://persistent.oaistatic.com/codex-app-prod/Codex.dmg

# Step 1: Download Codex DMG
RUN echo "=== Downloading Codex DMG ===" && \
    curl -L -o Codex.dmg "${CODEX_DMG_URL}" && \
    ls -lh Codex.dmg

# Step 2: Extract DMG
RUN echo "=== Extracting DMG ===" && \
    7z x Codex.dmg -oextracted/ -y && \
    find extracted -type f -name "*.app" -o -name "*.asar" | head -20

# Step 3: Extract ASAR
RUN echo "=== Extracting ASAR ===" && \
    ASAR_PATH=$(find extracted -name "app.asar" -type f | head -1) && \
    echo "Found: $ASAR_PATH" && \
    npm install -g asar && \
    asar extract "$ASAR_PATH" app_unpacked/ && \
    ls -la app_unpacked/

# Step 4: Clone and build Rust CLI
RUN echo "=== Cloning openai/codex ===" && \
    git clone --depth 1 https://github.com/openai/codex.git codex-src && \
    cd codex-src/codex-rs && \
    echo "=== Building Rust CLI (this takes 10-15 min) ===" && \
    cargo build --release --bin codex && \
    cargo build --release --bin codex-linux-sandbox || true && \
    ls -lh target/release/codex

# Step 5: Rebuild native modules (if needed)
RUN echo "=== Checking native modules ===" && \
    cd app_unpacked && \
    if [ -f node_modules/better-sqlite3/build/Release/better_sqlite3.node ]; then \
        npm rebuild better-sqlite3 || true; \
    fi && \
    if [ -f node_modules/node-pty/build/Release/pty.node ]; then \
        npm rebuild node-pty || true; \
    fi

# Step 6: Assemble final bundle
RUN echo "=== Assembling Linux bundle ===" && \
    cd app_unpacked && \
    rm -f native/sparkle.node && \
    rm -rf node_modules/electron-liquid-glass && \
    cp /build/codex-src/codex-rs/target/release/codex resources/codex && \
    chmod +x resources/codex && \
    cp /build/codex-src/codex-rs/target/release/codex-linux-sandbox resources/ 2>/dev/null || true && \
    chmod +x resources/codex-linux-sandbox 2>/dev/null || true

# Step 7: Create launcher script
RUN echo "=== Creating launcher ===" && \
    cat > app_unpacked/codex-linux.sh << 'EOF'
#!/bin/bash
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="${APP_DIR}/resources:${PATH}"
if command -v electron &> /dev/null; then
    exec electron "${APP_DIR}" "$@"
else
    echo "CLI available at: ${APP_DIR}/resources/codex"
    exit 1
fi
EOF
    chmod +x app_unpacked/codex-linux.sh

# Step 8: Copy to output directory
RUN mkdir -p /output && \
    cp -r app_unpacked /output/codex-linux && \
    cp resources/codex /output/codex && \
    echo "=== Build complete ===" && \
    ls -lh /output/codex && \
    file /output/codex

# Default: copy to mounted volume
CMD cp -r /output/* /output-mount/ 2>/dev/null || cp -r /output/codex-linux /tmp/ && echo "Build complete. Copy from /output or mount a volume."
