#!/bin/bash
# Build Codex for Linux using Docker
# One command to rule them all

set -e

echo "🐳 Building Codex Linux via Docker..."
echo "======================================"

# Build the Docker image
echo "📦 Building Docker image..."
docker build -t codex-builder .

# Create output directory
mkdir -p output

# Run the builder
echo "🔨 Running build container..."
docker run --rm -v "$(pwd)/output:/output-mount" codex-builder

echo ""
echo "✅ Build complete!"
echo "=================="
echo "📦 App bundle: ./output/codex-linux/"
echo "🔧 CLI binary: ./output/codex"
echo ""
echo "To install CLI system-wide:"
echo "  sudo cp ./output/codex /usr/local/bin/"
echo ""
echo "To run GUI (requires Electron):"
echo "  ./output/codex-linux/codex-linux.sh"
