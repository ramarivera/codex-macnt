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
ENABLE_LINUX_UI_POLISH="${ENABLE_LINUX_UI_POLISH:-1}"

rebuild_native_modules_on_host() {
    local app_dir="output/codex-linux"
    local native_build_dir="output/native-build-host"

    if [[ ! -d "${app_dir}" ]]; then
        return
    fi

    echo "🧩 Rebuilding native modules on host for Electron runtime..."

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "❌ node and npm are required on host for native module rebuild" >&2
        exit 1
    fi

    pushd "${app_dir}" >/dev/null
    PACKAGE_ELECTRON_VERSION=$(node -p "require('./package.json').devDependencies?.electron || ''" 2>/dev/null || true)
    PACKAGE_ELECTRON_VERSION="${PACKAGE_ELECTRON_VERSION#^}"

    HOST_ELECTRON_VERSION=""
    if command -v electron >/dev/null 2>&1; then
        HOST_ELECTRON_VERSION=$(electron --version 2>/dev/null || true)
        HOST_ELECTRON_VERSION="${HOST_ELECTRON_VERSION#v}"
        HOST_ELECTRON_VERSION="${HOST_ELECTRON_VERSION#^}"
    fi

    ELECTRON_VERSION="${HOST_ELECTRON_VERSION:-${PACKAGE_ELECTRON_VERSION}}"
    if [[ -z "${ELECTRON_VERSION}" ]]; then
        echo "❌ Unable to determine Electron version for native rebuild" >&2
        exit 1
    fi

    if [[ -n "${HOST_ELECTRON_VERSION}" ]]; then
        echo "ℹ️  Using host Electron ${HOST_ELECTRON_VERSION} for native rebuild"
    else
        echo "ℹ️  Using package Electron ${PACKAGE_ELECTRON_VERSION} for native rebuild"
    fi

    SQLITE_VERSION=$(node -p "require('./node_modules/better-sqlite3/package.json').version" 2>/dev/null || echo "12.5.0")
    PTY_VERSION=$(node -p "require('./node_modules/node-pty/package.json').version" 2>/dev/null || echo "1.1.0")
    popd >/dev/null

    rm -rf "${native_build_dir}"
    mkdir -p "${native_build_dir}"
    pushd "${native_build_dir}" >/dev/null
    npm init -y >/dev/null 2>&1

    npm_config_runtime=electron \
    npm_config_target="${ELECTRON_VERSION}" \
    npm_config_disturl=https://electronjs.org/headers \
    npm install --force --no-save "better-sqlite3@${SQLITE_VERSION}" "node-pty@${PTY_VERSION}" >/dev/null

    popd >/dev/null

    mkdir -p "${app_dir}/node_modules/better-sqlite3/build/Release"
    mkdir -p "${app_dir}/node_modules/node-pty/build/Release"
    cp -f "${native_build_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" "${app_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
    cp -f "${native_build_dir}/node_modules/node-pty/build/Release/pty.node" "${app_dir}/node_modules/node-pty/build/Release/pty.node"

    if ! file "${app_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" | grep -q ELF; then
        echo "❌ better-sqlite3 native binary is not Linux ELF" >&2
        exit 1
    fi

    if ! file "${app_dir}/node_modules/node-pty/build/Release/pty.node" | grep -q ELF; then
        echo "❌ node-pty native binary is not Linux ELF" >&2
        exit 1
    fi

    if ldd "${app_dir}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" | grep -q libnode; then
        echo "❌ better-sqlite3 still links libnode; incompatible with Electron runtime" >&2
        exit 1
    fi

    if ldd "${app_dir}/node_modules/node-pty/build/Release/pty.node" | grep -q libnode; then
        echo "❌ node-pty still links libnode; incompatible with Electron runtime" >&2
        exit 1
    fi

    echo "✅ Host native module rebuild complete"
}

run_host_orchestrator() {
    echo "🐳 Building Codex Linux via Docker..."
    echo "======================================"

    if ! command -v docker >/dev/null 2>&1; then
        echo "❌ docker is required to run this script" >&2
        exit 1
    fi

    echo "📦 Building Docker image..."
    docker build --no-cache -t codex-builder .

    mkdir -p output

    echo "🔨 Running build container..."
    docker run --rm \
      --cap-add SYS_ADMIN \
      --security-opt apparmor:unconfined \
      -e IN_DOCKER_BUILD=1 \
      -e WORKDIR=/output/work \
      -e INSTALL_DIR=/output \
      -e HOME=/build \
      -e CARGO_BUILD_JOBS=2 \
      -e ENABLE_LINUX_UI_POLISH="${ENABLE_LINUX_UI_POLISH}" \
      -v "$(pwd)/output:/output" \
      codex-builder

    if [[ -d output/work/app_unpacked ]]; then
        rm -rf output/codex-linux
        cp -a output/work/app_unpacked output/codex-linux
    fi

    rebuild_native_modules_on_host

    echo ""
    echo "✅ Build complete!"
    echo "=================="
    echo "📦 App bundle: ./output/codex-linux/"
    echo "🔧 CLI binary: ./output/codex"
    echo ""
    echo "To install CLI system-wide:"
    echo "  cp ./output/codex ~/.local/bin/"
    echo ""
    echo "To run GUI (requires Electron):"
    echo "  ./output/codex-linux/codex-linux.sh"
}

if [[ "${IN_DOCKER_BUILD:-0}" != "1" ]]; then
    run_host_orchestrator "$@"
    exit 0
fi

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

# Try musl target first only when cross-compiler exists.
if command -v x86_64-linux-musl-gcc >/dev/null 2>&1; then
    if cargo build --release --bin codex --target x86_64-unknown-linux-musl 2>&1; then
        TARGET_DIR="target/x86_64-unknown-linux-musl/release"
        BUILD_SUCCESS=true
        echo ""
        success "Built with musl (statically linked, most compatible)"
    elif rustup target add x86_64-unknown-linux-musl 2>/dev/null && cargo build --release --bin codex --target x86_64-unknown-linux-musl 2>&1; then
        TARGET_DIR="target/x86_64-unknown-linux-musl/release"
        BUILD_SUCCESS=true
        echo ""
        success "Built with musl after adding target"
    else
        echo ""
        substep "Musl build failed; falling back to native x86_64 target..."
        echo "   ════════════════════════════════════════════════════════════════════════"
    fi
else
    substep "Musl cross-compiler not found; skipping musl build and using native x86_64 target"
    echo "   ════════════════════════════════════════════════════════════════════════"
fi

# Fallback to native target when musl path is unavailable or fails.
if [[ "${BUILD_SUCCESS}" != "true" ]]; then
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

substep "Detecting Electron target for native module rebuild..."
ELECTRON_VERSION=$(node -p "require('./package.json').devDependencies?.electron || ''" 2>/dev/null | tr -d '^"')

if [[ -z "${ELECTRON_VERSION}" ]]; then
    substep "Electron version not found in package metadata"
else
    substep "Detected Electron ${ELECTRON_VERSION}"
fi

if [[ "${FORCE_CONTAINER_NATIVE_REBUILD:-0}" == "1" ]]; then
    substep "FORCE_CONTAINER_NATIVE_REBUILD=1, attempting in-container native rebuild..."
    npm rebuild better-sqlite3 2>&1 | tail -20 || substep "Warning: better-sqlite3 rebuild failed in container"
    npm rebuild node-pty 2>&1 | tail -20 || substep "Warning: node-pty rebuild failed in container"
else
    substep "Skipping in-container native rebuild; host rebuild in build-docker.sh handles Electron ABI"
fi

# Step 7: Replace macOS-specific files
step "7/11" "Replacing macOS components with Linux equivalents"

substep "Removing macOS-only native modules..."
rm -vf native/sparkle.node 2>/dev/null || substep "sparkle.node not found (ok)"
rm -vrf node_modules/electron-liquid-glass 2>/dev/null || substep "electron-liquid-glass not found (ok)"
success "Cleaned macOS-specific files"

substep "Creating resources directory..."
mkdir -p resources resources/bin

substep "Copying Linux CLI binary..."
cp -v "${WORKDIR}/codex-src/codex-rs/${TARGET_DIR}/codex" resources/codex
chmod -v +x resources/codex
cp -v resources/codex resources/bin/codex
chmod -v +x resources/bin/codex
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

if [[ "${ENABLE_LINUX_UI_POLISH}" == "1" ]]; then
    substep "Applying Linux UI polish stylesheet..."

    POLISH_CSS_PATH="${WORKDIR}/app_unpacked/webview/assets/linux-polish.css"
    INDEX_HTML_PATH="${WORKDIR}/app_unpacked/webview/index.html"

    cat > "${POLISH_CSS_PATH}" << 'POLISH_CSS_EOF'
:root {
  --linux-glass-bg: color-mix(in srgb, Canvas 78%, transparent);
  --linux-glass-bg-strong: color-mix(in srgb, Canvas 86%, transparent);
  --linux-glass-border: color-mix(in srgb, CanvasText 14%, transparent);
  --linux-glass-shadow: 0 10px 30px rgba(0, 0, 0, 0.25);
  --linux-glass-radius: 12px;
}

html,
body,
#root {
  background: radial-gradient(1200px 700px at 10% -10%, rgba(80, 120, 255, 0.08), transparent 60%),
              radial-gradient(900px 500px at 90% 0%, rgba(0, 200, 170, 0.07), transparent 55%);
}

nav,
aside,
[role="navigation"],
[class*="sidebar" i],
[class*="thread" i],
[class*="panel" i],
[class*="toolbar" i],
[class*="header" i] {
  background-color: var(--linux-glass-bg);
  border-color: var(--linux-glass-border) !important;
}

[class*="card" i],
[class*="surface" i],
[class*="composer" i],
input,
textarea,
button {
  border-radius: var(--linux-glass-radius);
}

@supports ((-webkit-backdrop-filter: blur(1px)) or (backdrop-filter: blur(1px))) {
  nav,
  aside,
  [role="navigation"],
  [class*="sidebar" i],
  [class*="thread" i],
  [class*="panel" i],
  [class*="toolbar" i],
  [class*="header" i] {
    -webkit-backdrop-filter: saturate(1.2) blur(14px);
    backdrop-filter: saturate(1.2) blur(14px);
    box-shadow: var(--linux-glass-shadow);
  }
}

@supports not ((-webkit-backdrop-filter: blur(1px)) or (backdrop-filter: blur(1px))) {
  nav,
  aside,
  [role="navigation"],
  [class*="sidebar" i],
  [class*="thread" i],
  [class*="panel" i],
  [class*="toolbar" i],
  [class*="header" i] {
    background-color: var(--linux-glass-bg-strong);
  }
}

* {
  scrollbar-width: thin;
}
POLISH_CSS_EOF

    if [[ -f "${INDEX_HTML_PATH}" ]]; then
        if grep -q 'linux-polish.css' "${INDEX_HTML_PATH}"; then
            substep "linux-polish.css already linked in index.html"
        else
            sed -i '/<link rel="stylesheet"/a\    <link rel="stylesheet" href="./assets/linux-polish.css">' "${INDEX_HTML_PATH}"
            success "Linked linux-polish.css in webview/index.html"
        fi
    else
        substep "Warning: webview/index.html not found; skipping CSS link injection"
    fi

    success "Linux UI polish applied"
else
    substep "Linux UI polish disabled (ENABLE_LINUX_UI_POLISH=${ENABLE_LINUX_UI_POLISH})"
fi

cat > codex-linux.sh << 'LAUNCHER_EOF'
#!/bin/bash
# Codex Linux Launcher - Auto-generated

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="${APP_DIR}/resources:${APP_DIR}/resources/bin:${PATH}"
export CODEX_CLI_PATH="${APP_DIR}/resources/bin/codex"

# Check for codex CLI
if [[ ! -f "${CODEX_CLI_PATH}" ]]; then
    echo "❌ Error: codex binary not found at ${CODEX_CLI_PATH}" >&2
    exit 1
fi

# Launch Electron if available, otherwise suggest CLI
if command -v electron &> /dev/null; then
    exec electron "${APP_DIR}" "$@"
else
    echo "ℹ️  Electron not installed. Run CLI mode instead:" >&2
    echo "   ${CODEX_CLI_PATH}" >&2
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
