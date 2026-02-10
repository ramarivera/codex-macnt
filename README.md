# Codex for Linux

Extract OpenAI's Codex from macOS DMG and run it on Linux.

## Quick Start

```bash
# Clone and enter repo
cd codex-linux

# Install dependencies and run build
./install-codex-linux.sh
```

This will:
1. Download Codex DMG from OpenAI CDN
2. Extract the Electron app bundle
3. Compile the Rust CLI for Linux
4. Install `codex` to `~/.local/bin/`

## Requirements

- Linux (x86_64)
- 7z (`p7zip-full`)
- Rust 1.93+
- Node.js + npm
- dmg2img

## Usage

```bash
# CLI mode
codex login
codex "your coding task"

# GUI mode (requires Electron)
npm install -g electron
~/.cache/codex-linux-port/app_unpacked/codex-linux.sh
```

## What This Does

Codex is OpenAI's desktop coding assistant. The official release is macOS-only. This tool:

- Extracts the UI/resources from the macOS DMG
- Compiles the Rust CLI core for Linux (from openai/codex repo)
- Swaps the macOS binary with the Linux binary
- Removes macOS-only native modules (Sparkle, liquid-glass)

## Files

- `install-codex-linux.sh` - Main installation script
- `reverse_analysis/` - Reverse engineering documentation
- `mise.toml` - Build environment configuration
- `Dockerfile` / `docker-compose.yml` - Container build (optional)

## Legal

This is an **unofficial** tool for educational purposes. All Codex branding and code belongs to OpenAI. The Rust CLI is MIT-licensed from github.com/openai/codex.

Use at your own risk. Not endorsed by OpenAI.
