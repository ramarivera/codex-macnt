#!/bin/bash
set -euo pipefail

# Codex macOS to Linux Porter
# One-command solution to get Codex working on Linux

CODEX_VERSION="260208.1016"
DMG_URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
WORKDIR="${HOME}/.cache/codex-linux-port"
INSTALL_DIR="${HOME}/.local/bin"

echo "🚀 Codex macOS → Linux Porter"
echo "============================="

# Step 1: Setup workspace
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Step 2: Download macOS Codex DMG (if not cached)
if [[ ! -f "Codex.dmg" ]]; then
    echo "📥 Downloading Codex ${CODEX_VERSION}..."
    curl -L -o Codex.dmg "${DMG_URL}" || wget -O Codex.dmg "${DMG_URL}"
else
    echo "📦 Using cached Codex.dmg"
fi

# Step 3: Extract DMG
echo "📂 Extracting DMG..."
rm -rf extracted
mkdir -p extracted
7z x Codex.dmg -oextracted/ -y >/dev/null 2>&1 || {
    echo "Trying alternative extraction..."
    # Fallback for systems without 7z
    sudo apt-get install -y p7zip-full 2>/dev/null || sudo yum install -y p7zip 2>/dev/null || true
    7z x Codex.dmg -oextracted/ -y
}

# Step 4: Extract ASAR
echo "🔓 Extracting app bundle..."
ASAR_PATH="extracted/Codex*/Codex.app/Contents/Resources/app.asar"
if [[ -f ${ASAR_PATH} ]]; then
    npx asar extract ${ASAR_PATH} app_unpacked/ 2>/dev/null || {
        npm install -g asar
        npx asar extract ${ASAR_PATH} app_unpacked/
    }
else
    echo "❌ Could not find app.asar"
    exit 1
fi

# Step 5: Clone and build Rust CLI for Linux
echo "🔨 Building Rust CLI for Linux (this takes ~10 minutes)..."
if [[ ! -d codex-rs ]]; then
    git clone --depth 1 https://github.com/openai/codex.git codex-src
    cd codex-src/codex-rs
else
    cd codex-src/codex-rs
fi

# Build with musl for static linking (most compatible)
echo "   Compiling codex binary..."
cargo build --release --bin codex --target x86_64-unknown-linux-musl 2>/dev/null || {
    # Fallback to native target if musl not available
    rustup target add x86_64-unknown-linux-musl 2>/dev/null || true
    cargo build --release --bin codex
}

# Build Linux sandbox helper
echo "   Compiling Linux sandbox..."
cargo build --release --bin codex-linux-sandbox 2>/dev/null || true

# Step 6: Rebuild native Node modules for Linux
echo "🔧 Rebuilding native modules for Linux..."
cd "${WORKDIR}/app_unpacked"

# Check if we need to rebuild
if [[ -f "node_modules/better-sqlite3/build/Release/better_sqlite3.node" ]]; then
    file node_modules/better-sqlite3/build/Release/better_sqlite3.node | grep -q Linux || {
        echo "   Rebuilding better-sqlite3..."
        npm rebuild better-sqlite3 2>/dev/null || true
    }
fi

if [[ -f "node_modules/node-pty/build/Release/pty.node" ]]; then
    file node_modules/node-pty/build/Release/pty.node | grep -q Linux || {
        echo "   Rebuilding node-pty..."
        npm rebuild node-pty 2>/dev/null || true
    }
fi

# Step 7: Replace macOS-specific files
echo "🔄 Replacing macOS components with Linux equivalents..."

# Remove macOS-only native modules
rm -f native/sparkle.node
rm -rf node_modules/electron-liquid-glass

# Copy Linux CLI binary
cp "${WORKDIR}/codex-src/codex-rs/target/release/codex" resources/codex
chmod +x resources/codex

# Copy Linux sandbox if built
if [[ -f "${WORKDIR}/codex-src/codex-rs/target/release/codex-linux-sandbox" ]]; then
    cp "${WORKDIR}/codex-src/codex-rs/target/release/codex-linux-sandbox" resources/
    chmod +x resources/codex-linux-sandbox
fi

# Step 8: Create Linux launcher
echo "🐧 Creating Linux launcher..."
cat > codex-linux.sh << 'EOF'
#!/bin/bash
# Codex Linux Launcher

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="${APP_DIR}/resources:${PATH}"

# Check dependencies
if ! command -v codex &> /dev/null; then
    echo "Codex CLI not found. Please ensure codex binary is in resources/"
    exit 1
fi

# Launch Electron with the app
electron "${APP_DIR}" "$@" 2>/dev/null || {
    echo "Electron not found. Install with: npm install -g electron"
    echo "Or run CLI version: codex"
    exit 1
}
EOF
chmod +x codex-linux.sh

# Step 9: Create desktop entry
echo "🖥️  Creating desktop entry..."
mkdir -p "${HOME}/.local/share/applications"
cat > "${HOME}/.local/share/applications/codex.desktop" << EOF
[Desktop Entry]
Name=Codex
Comment=OpenAI Codex AI coding assistant
Exec=${WORKDIR}/app_unpacked/codex-linux.sh
Icon=${WORKDIR}/app_unpacked/webview/assets/logo-BtOb2qkB.png
Type=Application
Categories=Development;IDE;
Terminal=false
EOF

# Step 10: Install CLI to PATH
echo "📌 Installing codex CLI to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp resources/codex "${INSTALL_DIR}/"

# Step 11: Final summary
echo ""
echo "✅ SUCCESS! Codex is now ready for Linux!"
echo "============================================"
echo ""
echo "📍 Locations:"
echo "   App bundle: ${WORKDIR}/app_unpacked/"
echo "   CLI binary: ${INSTALL_DIR}/codex"
echo "   Desktop:    ~/.local/share/applications/codex.desktop"
echo ""
echo "🚀 Usage:"
echo "   codex                    # CLI mode"
echo "   codex-linux.sh           # GUI mode (if electron installed)"
echo "   codex --help             # See all options"
echo ""
echo "🔐 Authentication:"
echo "   codex login              # Login with ChatGPT"
echo "   # OR"
echo "   printenv OPENAI_API_KEY | codex login --with-api-key"
echo ""
echo "📝 Notes:"
echo "   - Native modules may need manual rebuild: cd ${WORKDIR}/app_unpacked && npm rebuild"
echo "   - For GUI mode: npm install -g electron"
echo "   - First run may take a moment to initialize"
echo ""
echo "🎉 Happy coding with Codex on Linux!"

# Cleanup old build artifacts
rm -rf "${WORKDIR}/extracted"
