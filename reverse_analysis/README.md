# Codex Linux Reverse Engineering Analysis

## Architecture Overview

- Frontend: React + Vite webview
- Backend: Electron + Node.js main process
- Core: Rust CLI binary (codex)
- Protocol: JSON-RPC via WebSocket
- Sandboxing: Landlock+seccomp (Linux), Seatbelt (macOS)

## Native Dependencies

- better-sqlite3 (needs rebuild)
- node-pty (needs rebuild)
- sparkle.node (macOS only - replace for Linux)
- electron-liquid-glass (macOS only - replace for Linux)
