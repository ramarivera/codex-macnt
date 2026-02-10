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
