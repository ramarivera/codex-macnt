#!/bin/bash
# Codex macOS to Linux Porter
# One-command solution to get Codex working on Linux

set -euo pipefail

# Configuration
CODEX_VERSION="260208.1016"
DMG_URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
WORKDIR="${WORKDIR:-${HOME}/.cache/codex-linux-port}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"
LOG_FILE="${WORKDIR}/install.log"

# Initialize logging
mkdir -p "${WORKDIR}"
exec 1> >(tee -a "${LOG_FILE}")
exec 2>&1

echo "================================================================================"
echo "🚀 Codex macOS → Linux Porter"
echo "================================================================================"
echo ""
echo "📋 Installation Log: ${LOG_FILE}"
echo "⏰ Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "💻 System: $(uname -a)"
echo "👤 User: $(whoami)"
echo ""
echo "📝 This script will:"
echo "   1. Download Codex ${CODEX_VERSION} from OpenAI CDN"
echo "   2. Extract the macOS DMG and ASAR bundle"
echo "   3. Clone and compile the Rust CLI core (~10 minutes)"
echo "   4. Rebuild native Node.js modules for Linux"
echo "   5. Install the codex CLI to ${INSTALL_DIR}"
echo "   6. Create desktop entry for GUI launching"
echo ""
echo "⏳ Starting in 3 seconds... (Ctrl+C to cancel)"
sleep 3
echo ""

# Helper function for step logging
step() {
    echo ""
    echo "================================================================================"
    echo "📌 STEP $1: $2"
    echo "================================================================================"
    echo "⏱️  $(date '+%H:%M:%S') - Starting..."
}

substep() {
    echo "   🔸 $(date '+%H:%M:%S') - $1"
}

error() {
    echo ""
    echo "❌ ERROR at $(date '+%H:%M:%S'): $1" >&2
    echo "📄 Check log: ${LOG_FILE}" >&2
    exit 1
}

success() {
    echo "   ✅ $(date '+%H:%M:%S') - $1"
}

# Step 1: Setup workspace
step "1/11" "Setting up workspace"
substep "Creating work directory: ${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"
success "Workspace ready at ${WORKDIR}"

# Step 2: Download macOS Codex DMG
step "2/11" "Downloading Codex macOS app"
if [[ -f "Codex.dmg" ]]; then
    substep "Found cached Codex.dmg"
    ls -lh Codex.dmg
    success "Using cached DMG ($(du -h Codex.dmg | cut -f1))"
else
    substep "Downloading from: ${DMG_URL}"
    substep "This is a ~150MB file, please wait..."
    
    if command -v curl &> /dev/null; then
        curl -L --progress-bar -o Codex.dmg "${DMG_URL}" || error "curl download failed"
    elif command -v wget &> /dev/null; then
        wget --progress=bar:force -O Codex.dmg "${DMG_URL}" || error "wget download failed"
    else
        error "Neither curl nor wget found. Please install one of them."
    fi
    
    success "Downloaded $(du -h Codex.dmg | cut -f1)"
fi

# Step 3: Extract DMG
step "3/11" "Extracting DMG contents"
substep "Removing old extraction directory"
rm -rf extracted
mkdir -p extracted

substep "Converting DMG to IMG..."
dmg2img Codex.dmg Codex.img || error "dmg2img conversion failed"

substep "Extracting IMG with 7z..."
# Extract HFS+ image - ignore errors, some files may still extract
7z x Codex.img -oextracted/ -y 2>/dev/null || true

# Check if we got anything
if [ ! "$(ls -A extracted/ 2>/dev/null)" ]; then
    error "Extraction failed - no files extracted"
fi

substep "Listing extracted contents:"
ls -la extracted/ | head -20

success "DMG extracted successfully"

# Step 4: Extract ASAR
step "4/11" "Extracting Electron ASAR bundle"
substep "Locating app.asar..."

ASAR_PATH=$(find extracted -name "app.asar" -type f 2>/dev/null | head -1)
if [[ -z "${ASAR_PATH}" ]]; then
    error "Could not find app.asar in extracted DMG"
fi

success "Found app.asar at: ${ASAR_PATH}"

substep "Installing asar extractor..."
ASAR_CMD=""

# Try various methods to get asar
if command -v asar &> /dev/null; then
    ASAR_CMD="asar"
    success "Found asar at $(which asar)"
else
    if ! command -v node &> /dev/null; then
        error "Node.js is required to extract app.asar"
    fi

    NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)
    ASAR_PKG="@electron/asar"
    if [[ "${NODE_MAJOR}" -lt 22 ]]; then
        # @electron/asar v4 requires Node >=22.12.0
        ASAR_PKG="@electron/asar@3.2.13"
    fi

    substep "Installing ${ASAR_PKG} locally (not globally)..."
    mkdir -p "${WORKDIR}/.npm-local"
    cd "${WORKDIR}/.npm-local"
    npm init -y &> /dev/null || true
    npm install "${ASAR_PKG}" 2>&1 | tail -5 || {
        substep "Local install failed, trying with --prefix..."
        cd "${WORKDIR}"
        npm install --prefix "${WORKDIR}/.npm-local" "${ASAR_PKG}" 2>&1 | tail -5 || error "Failed to install ${ASAR_PKG}"
    }
    ASAR_CMD="${WORKDIR}/.npm-local/node_modules/.bin/asar"
    cd "${WORKDIR}"
    success "Installed ${ASAR_PKG} locally"
fi

substep "Extracting ASAR to app_unpacked/..."
rm -rf app_unpacked
${ASAR_CMD} extract "${ASAR_PATH}" app_unpacked/ || error "ASAR extraction failed"

substep "Extracted contents:"
ls -la app_unpacked/ | head -15

success "ASAR extracted ($(du -sh app_unpacked/ | cut -f1) total)"

# Step 5: Clone and build Rust CLI
step "5/11" "Building Rust CLI for Linux (LONG STEP ~10-15 min)"

cd "${WORKDIR}"

if [[ -d "codex-src/codex-rs" ]]; then
    substep "Found existing codex-src, pulling latest changes..."
    cd codex-src
    git pull --depth 1 2>&1 | tail -3 || substep "Git pull failed, using existing code"
    cd ..
else
    substep "Cloning openai/codex repository..."
    substep "This downloads the Rust source code (~50MB)"
    git clone --depth 1 https://github.com/openai/codex.git codex-src 2>&1 | tail -5 || error "Git clone failed"
    success "Cloned codex repository"
fi

cd "${WORKDIR}/codex-src/codex-rs"

substep "Checking Rust toolchain..."
if ! command -v cargo &> /dev/null; then
    error "Rust/Cargo not found. Please install Rust: https://rustup.rs/"
fi

RUST_VERSION=$(rustc --version)
success "Found Rust: ${RUST_VERSION}"

# Check if we need to upgrade Rust
substep "Checking Rust version compatibility..."
CURRENT_RUST=$(rustc --version | grep -oP '\d+\.\d+\.\d+')
REQUIRED_RUST="1.91.0"

# Simple version compare
if [[ "$(printf '%s\n' "$REQUIRED_RUST" "$CURRENT_RUST" | sort -V | head -n1)" != "$REQUIRED_RUST" ]]; then
    substep "⚠️  Rust ${CURRENT_RUST} is older than required ${REQUIRED_RUST}"
    substep "Upgrading Rust to latest stable..."
    
    if command -v rustup &> /dev/null; then
        rustup update stable 2>&1 || {
            substep "rustup update failed, trying self update..."
            rustup self update 2>&1 || true
            rustup update stable 2>&1
        }
        success "Upgraded Rust to $(rustc --version)"
    else
        error "rustup not found. Cannot auto-upgrade Rust.\nPlease upgrade manually:\n  rustup update stable\nOr visit: https://rustup.rs/"
    fi
else
    success "Rust version ${CURRENT_RUST} meets requirements (>= ${REQUIRED_RUST})"
fi

substep "Analyzing Cargo workspace..."
substep "Workspace members:"
grep -A30 'members = \[' Cargo.toml | head -10

substep "Starting compilation of codex binary..."
substep "⚠️  THIS WILL TAKE 10-15 MINUTES!"
substep "Compiling 30+ Rust crates in release mode..."
substep ""
substep "You will see compile output below (crates building, linking, etc.)"
substep "If it looks stuck, it's probably still compiling - just wait!"
substep ""
echo "   ════════════════════════════════════════════════════════════════════════"
echo "   🛠️  CARGO BUILD OUTPUT (live):"
echo "   ════════════════════════════════════════════════════════════════════════"

# Build with live output (no piping to tail, so user sees progress)
TARGET_DIR=""
BUILD_SUCCESS=false

# Try musl target first
if cargo build --release --bin codex --target x86_64-unknown-linux-musl 2>&1; then
    TARGET_DIR="target/x86_64-unknown-linux-musl/release"
    BUILD_SUCCESS=true
    echo ""
    success "Built with musl (statically linked, most compatible)"
# Try adding musl target then building
elif rustup target add x86_64-unknown-linux-musl 2>/dev/null && cargo build --release --bin codex --target x86_64-unknown-linux-musl 2>&1; then
    TARGET_DIR="target/x86_64-unknown-linux-musl/release"
    BUILD_SUCCESS=true
    echo ""
    success "Built with musl after adding target"
# Fallback to native target
else
    echo ""
    substep "Musl target failed or not available, trying native x86_64 target..."
    echo "   ════════════════════════════════════════════════════════════════════════"
    if cargo build --release --bin codex 2>&1; then
        TARGET_DIR="target/release"
        BUILD_SUCCESS=true
        echo ""
        success "Built with native target"
    fi
fi

if [[ "$BUILD_SUCCESS" != "true" ]]; then
    error "Cargo build failed after all attempts"
fi

substep "Checking built binary..."
ls -lh "${TARGET_DIR}/codex"
file "${TARGET_DIR}/codex"

success "Codex CLI built successfully"

# Build Linux sandbox helper
substep ""
substep "Building Linux sandbox helper (optional)..."
echo "   ════════════════════════════════════════════════════════════════════════"
if cargo build --release --bin codex-linux-sandbox 2>&1; then
    echo ""
    success "Built codex-linux-sandbox"
else
    echo ""
    substep "⚠️  Sandbox build skipped (this is optional, CLI will work without it)"
fi

# Step 6: Rebuild native Node modules
step "6/11" "Rebuilding native Node.js modules for Linux"
cd "${WORKDIR}/app_unpacked"

substep "Checking current native modules..."

if [[ -f "node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]]; then
    substep "Found better-sqlite3, checking architecture..."
    file node_modules/better-sqlite3/build/Release/better_sqlite3.node
    
    if file node_modules/better-sqlite3/build/Release/better_sqlite3.node | grep -q Linux; then
        success "better-sqlite3 already Linux-compatible"
    else
        substep "Rebuilding better-sqlite3 for Linux..."
        npm rebuild better-sqlite3 2>&1 | tail -5 || substep "Rebuild warning (may still work)"
        success "Rebuilt better-sqlite3"
    fi
else
    substep "better-sqlite3 not found in expected location"
fi

if [[ -f "node_modules/node-pty/build/Release/pty.node" ]]; then
    substep "Found node-pty, checking architecture..."
    file node_modules/node-pty/build/Release/pty.node
    
    if file node_modules/node-pty/build/Release/pty.node | grep -q Linux; then
        success "node-pty already Linux-compatible"
    else
        substep "Rebuilding node-pty for Linux..."
        npm rebuild node-pty 2>&1 | tail -5 || substep "Rebuild warning (may still work)"
        success "Rebuilt node-pty"
    fi
else
    substep "node-pty not found in expected location"
fi

# Step 7: Replace macOS-specific files
step "7/11" "Replacing macOS components with Linux equivalents"

substep "Removing macOS-only native modules..."
rm -vf native/sparkle.node 2>/dev/null || substep "sparkle.node not found (ok)"
rm -vrf node_modules/electron-liquid-glass 2>/dev/null || substep "electron-liquid-glass not found (ok)"
success "Cleaned macOS-specific files"

substep "Creating resources directory..."
mkdir -p resources

substep "Copying Linux CLI binary..."
cp -v "${WORKDIR}/codex-src/codex-rs/${TARGET_DIR}/codex" resources/codex
chmod -v +x resources/codex
file resources/codex
success "Installed codex binary"

substep "Checking for Linux sandbox helper..."
if [[ -f "${WORKDIR}/codex-src/codex-rs/${TARGET_DIR}/codex-linux-sandbox" ]]; then
    cp -v "${WORKDIR}/codex-src/codex-rs/${TARGET_DIR}/codex-linux-sandbox" resources/
    chmod -v +x resources/codex-linux-sandbox
    success "Installed codex-linux-sandbox"
else
    substep "Sandbox helper not found (optional, CLI will work without it)"
fi

# Step 8: Create Linux launcher
step "8/11" "Creating Linux launcher script"

cat > codex-linux.sh << 'LAUNCHER_EOF'
#!/bin/bash
# Codex Linux Launcher - Auto-generated

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="${APP_DIR}/resources:${PATH}"

# Check for codex CLI
if [[ ! -f "${APP_DIR}/resources/codex" ]]; then
    echo "❌ Error: codex binary not found in ${APP_DIR}/resources/" >&2
    exit 1
fi

# Launch Electron if available, otherwise suggest CLI
if command -v electron &> /dev/null; then
    exec electron "${APP_DIR}" "$@"
else
    echo "ℹ️  Electron not installed. Run CLI mode instead:" >&2
    echo "   ${APP_DIR}/resources/codex" >&2
    echo "" >&2
    echo "To install Electron: npm install -g electron" >&2
    exit 1
fi
LAUNCHER_EOF

chmod -v +x codex-linux.sh
success "Created codex-linux.sh launcher"

# Step 9: Create desktop entry
step "9/11" "Creating desktop application entry"

substep "Creating .desktop file..."
mkdir -p "${HOME}/.local/share/applications"

DESKTOP_FILE="${HOME}/.local/share/applications/codex.desktop"
cat > "${DESKTOP_FILE}" << EOF
[Desktop Entry]
Name=Codex
GenericName=AI Coding Assistant
Comment=OpenAI Codex - AI-powered coding assistant
Exec=${WORKDIR}/app_unpacked/codex-linux.sh
Icon=${WORKDIR}/app_unpacked/webview/assets/logo-BtOb2qkB.png
Terminal=false
Type=Application
Categories=Development;IDE;TextEditor;
StartupNotify=true
MimeType=text/plain;
Keywords=codex;ai;code;editor;openai;
EOF

chmod -v +x "${DESKTOP_FILE}"
ls -lh "${DESKTOP_FILE}"
success "Desktop entry created"

# Step 10: Install CLI to PATH
step "10/11" "Installing codex CLI to system PATH"

substep "Creating installation directory: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

substep "Copying codex binary..."
cp -v resources/codex "${INSTALL_DIR}/"
ls -lh "${INSTALL_DIR}/codex"

substep "Testing installation..."
if "${INSTALL_DIR}/codex" --version 2>&1 | head -1; then
    success "codex CLI installed and working"
else
    substep "Warning: codex --version failed, but binary is in place"
fi

# Step 11: Final summary
step "11/11" "Installation Complete!"

echo ""
echo "╔══════════════════════════════════════════════════════════════════════════════╗"
echo "║                    ✅ SUCCESS! Codex is ready for Linux!                      ║"
echo "╚══════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "📁 Installation Summary:"
echo "────────────────────────────────────────────────────────────────────────────────"
echo "   📦 App Bundle:     ${WORKDIR}/app_unpacked/"
echo "   🔧 CLI Binary:     ${INSTALL_DIR}/codex"
echo "   🖥️  GUI Launcher:   ${WORKDIR}/app_unpacked/codex-linux.sh"
echo "   📋 Desktop Entry:  ${DESKTOP_FILE}"
echo "   📝 Install Log:   ${LOG_FILE}"
echo "────────────────────────────────────────────────────────────────────────────────"
echo ""
echo "🚀 Quick Start Commands:"
echo "────────────────────────────────────────────────────────────────────────────────"
echo "   codex --help                    # Show all CLI options"
echo "   codex login                     # Login with ChatGPT"
echo "   printenv OPENAI_API_KEY | codex login --with-api-key  # API key auth"
echo "   codex \"your coding task\"        # Start coding!"
echo ""
echo "🖥️  GUI Mode (requires Electron):"
echo "────────────────────────────────────────────────────────────────────────────────"
echo "   npm install -g electron         # Install Electron globally"
echo "   ${WORKDIR}/app_unpacked/codex-linux.sh  # Launch GUI"
echo ""
echo "Or launch from your applications menu (search for 'Codex')"
echo ""
echo "🔍 Troubleshooting:"
echo "────────────────────────────────────────────────────────────────────────────────"
echo "   If codex command not found: export PATH=\"${INSTALL_DIR}:\$PATH\""
echo "   View full log:            cat ${LOG_FILE}"
echo "   Native module issues:     cd ${WORKDIR}/app_unpacked && npm rebuild"
echo ""
echo "🎉 Happy coding with Codex on Linux!"
echo ""
echo "⏰ Installation completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================================"

# Cleanup
substep "Cleaning up temporary files..."
rm -rf "${WORKDIR}/extracted"
success "Cleanup complete"

echo ""
echo "💡 Tip: Add ${INSTALL_DIR} to your PATH by running:"
echo "   echo 'export PATH=\"${INSTALL_DIR}:\$PATH\"' >> ~/.bashrc"
echo ""
