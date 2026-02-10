#!/bin/bash
# Build Codex for Linux using Docker

set -euo pipefail

echo "🐳 Building Codex Linux via Docker..."
echo "======================================"

# Build the Docker image
echo "📦 Building Docker image..."
docker build --no-cache -t codex-builder .

# Create output directory
mkdir -p output

# Run the builder
echo "🔨 Running build container..."
docker run --rm \
  --cap-add SYS_ADMIN \
  --security-opt apparmor:unconfined \
  -e WORKDIR=/output/work \
  -e INSTALL_DIR=/output \
  -e HOME=/build \
  -e CARGO_BUILD_JOBS=2 \
  -v "$(pwd)/output:/output" \
  codex-builder

# Keep app bundle in a stable output path
if [[ -d output/work/app_unpacked ]]; then
  rm -rf output/codex-linux
  cp -a output/work/app_unpacked output/codex-linux
fi

APP_DIR="output/codex-linux"
NATIVE_BUILD_DIR="output/native-build-host"

if [[ -d "${APP_DIR}" ]]; then
  echo "🧩 Rebuilding native modules on host for Electron runtime..."

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "❌ node and npm are required on host for native module rebuild" >&2
    exit 1
  fi

  pushd "${APP_DIR}" >/dev/null
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

  rm -rf "${NATIVE_BUILD_DIR}"
  mkdir -p "${NATIVE_BUILD_DIR}"
  pushd "${NATIVE_BUILD_DIR}" >/dev/null
  npm init -y >/dev/null 2>&1

  npm_config_runtime=electron \
  npm_config_target="${ELECTRON_VERSION}" \
  npm_config_disturl=https://electronjs.org/headers \
  npm install --force --no-save "better-sqlite3@${SQLITE_VERSION}" "node-pty@${PTY_VERSION}" >/dev/null

  popd >/dev/null

  mkdir -p "${APP_DIR}/node_modules/better-sqlite3/build/Release"
  mkdir -p "${APP_DIR}/node_modules/node-pty/build/Release"
  cp -f "${NATIVE_BUILD_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  cp -f "${NATIVE_BUILD_DIR}/node_modules/node-pty/build/Release/pty.node" "${APP_DIR}/node_modules/node-pty/build/Release/pty.node"

  if ! file "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" | grep -q ELF; then
    echo "❌ better-sqlite3 native binary is not Linux ELF" >&2
    exit 1
  fi

  if ! file "${APP_DIR}/node_modules/node-pty/build/Release/pty.node" | grep -q ELF; then
    echo "❌ node-pty native binary is not Linux ELF" >&2
    exit 1
  fi

  if ldd "${APP_DIR}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" | grep -q libnode; then
    echo "❌ better-sqlite3 still links libnode; incompatible with Electron runtime" >&2
    exit 1
  fi

  if ldd "${APP_DIR}/node_modules/node-pty/build/Release/pty.node" | grep -q libnode; then
    echo "❌ node-pty still links libnode; incompatible with Electron runtime" >&2
    exit 1
  fi

  echo "✅ Host native module rebuild complete"
fi

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
