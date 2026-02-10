# OpenAI Codex Reverse Engineering Analysis

## Executive Summary

**Codex** is OpenAI's official desktop application for their Codex AI coding assistant. It's built as an Electron app wrapping a Rust-based CLI core with an MCP (Model Context Protocol) architecture.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Electron Shell                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │   Main       │  │   Preload    │  │   Webview UI     │  │
│  │   Process    │  │   Script     │  │   (React+Vite)   │  │
│  │              │  │              │  │                  │  │
│  │  Node.js     │  │  Bridge      │  │  React App       │  │
│  │  + Native    │  │  IPC         │  │  + Skills UI     │  │
│  │  Modules     │  │  Security    │  │  + Terminal      │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────┘  │
│         │                 │                                 │
│         └─────────────────┘                                 │
│                    │                                        │
│         ┌──────────▼──────────┐                           │
│         │   Rust CLI Core     │                           │
│         │   (codex binary)    │                           │
│         │                     │                           │
│         │  • MCP Server       │                           │
│         │  • Protocol Handler │                           │
│         │  • Sandboxing       │                           │
│         │  • Cloud Tasks      │                           │
│         └─────────────────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

## File Structure Analysis

### DMG Contents
```
Codex.dmg (151MB compressed, 565MB uncompressed)
└── Codex Installer/
    └── Codex.app/
        ├── Contents/
        │   ├── Info.plist (App metadata)
        │   ├── MacOS/
        │   │   └── Codex (53KB - Electron launcher)
        │   ├── Resources/
        │   │   ├── app.asar (33MB - Main app code)
        │   │   ├── codex (55MB - Rust CLI binary)
        │   │   ├── rg (ripgrep binary)
        │   │   └── notification.wav
        │   └── _CodeSignature/ (Apple signing)
```

### ASAR Unpacked Structure
```
app.asar unpacked:
├── .vite/build/          # Vite bundled code
│   ├── main.js           # Entry point (loader)
│   ├── main-BLcwFbOH.js # Main process code
│   ├── preload.js        # Preload script
│   ├── index-DvdoEcOI.js # Renderer code
│   └── worker.js         # Worker threads
├── webview/              # React frontend
│   ├── index.html        # HTML entry
│   ├── assets/           # JS/CSS bundles
│   └── apps/             # IDE icons (VSCode, Cursor, etc)
├── native/
│   └── sparkle.node      # macOS auto-updater
├── node_modules/         # Native deps
│   ├── better-sqlite3/   # SQLite bindings
│   ├── node-pty/         # Terminal PTY
│   └── electron-liquid-glass/ # macOS UI effects
├── skills/               # AI skills directory
└── package.json          # App manifest
```

## Key Technical Details

### Package.json Analysis
```json
{
  "name": "openai-codex-electron",
  "version": "260208.1016",
  "main": ".vite/build/main.js",
  
  // Build system: Electron Forge + Vite
  "scripts": {
    "build": "electron-forge make -- --platform=darwin --arch=arm64",
    "forge:make": "electron-forge make"
  },
  
  // Has Linux makers!
  "devDependencies": {
    "@electron-forge/maker-deb": "^7.10.2",    // Debian/Ubuntu
    "@electron-forge/maker-rpm": "^7.10.2",     // Fedora/RHEL
    "@electron-forge/maker-zip": "^7.10.2"      // Generic
  },
  
  // Native dependencies requiring rebuild
  "dependencies": {
    "better-sqlite3": "^12.4.6",    // Needs recompilation
    "node-pty": "^1.1.0",           # Needs recompilation
    "electron-liquid-glass": "1.1.1"  # macOS only
  }
}
```

### Info.plist Key Values
- **Bundle ID**: `com.openai.codex`
- **Version**: `260208.1016` (YYMMDD.HHMM format)
- **Build**: `571`
- **Min macOS**: 12.0
- **SDK**: macOS 15.5
- **Category**: Developer Tools
- **URL Scheme**: `codex://`

## Native Components

### 1. Rust CLI Binary (`codex`)
**Size**: 55MB (ARM64 Mach-O)
**Language**: Rust (evident from symbol names like `codex_core::auth`)

**Capabilities**:
- MCP Server implementation (`codex_mcp_server`)
- WebSocket protocol handler
- Sandboxing (Landlock+seccomp on Linux, Seatbelt on macOS)
- Cloud Tasks support
- Multiple auth methods (ChatGPT, API Key, OAuth)
- SQLite database operations
- Terminal PTY management

**Linux Support**: The CLI already has Linux sandboxing support:
```
"linuxRun a command under Landlock+seccomp (Linux only)"
"codex-linux-sandbox executable not found"
```

### 2. Native Node Modules

#### better-sqlite3
- **Purpose**: SQLite database for thread/conversation storage
- **Current**: ARM64 macOS binary
- **Linux**: Requires `npm rebuild` for target arch

#### node-pty
- **Purpose**: Terminal PTY for interactive shell sessions
- **Current**: ARM64 macOS binary
- **Linux**: Requires rebuild against Linux headers

#### sparkle.node
- **Purpose**: macOS Sparkle auto-updater framework
- **Current**: ARM64 Mach-O bundle
- **Linux**: Replace with electron-updater or similar

#### electron-liquid-glass
- **Purpose**: macOS glass/blur effects
- **Current**: macOS-specific
- **Linux**: Replace or disable for Linux builds

## Protocol Analysis

### JSON-RPC App Server Protocol
The app uses a structured JSON-RPC protocol between Electron and Rust core:

```rust
// Protocol structs from binary strings:
struct InitializeParams { ... }
struct ThreadStartParams { ... }
struct SendUserTurnParams { ... }
struct ClientRequest { ... }
struct ClientInfo { ... }
```

### WebSocket Communication
- Real-time bidirectional communication
- Thread management (create, fork, resume, archive)
- Tool calling (MCP protocol)
- File operations with fuzzy search

### MCP (Model Context Protocol)
The app implements MCP for extensible tool support:
```
codex_mcp_server
codex_mcp_tool_call_id
codex_mcp_client
```

## Security Features

### Sandboxing
1. **macOS**: Seatbelt (app sandbox) + SIP
2. **Linux**: Landlock LSM + seccomp-bpf
3. **Windows**: Restricted token + integrity levels

### Code Signing
- Apple Developer ID signed
- ASAR integrity hash in Info.plist
- Electron fuses configured

## Auto-Update System
- **macOS**: Sparkle framework
- **Feed URL**: `https://persistent.oaistatic.com/codex-app-prod/appcast.xml`
- **Linux**: Needs electron-updater implementation

## Build System Analysis

### Electron Forge Configuration
```javascript
// Inferred from package.json:
{
  "makers": [
    { "name": "@electron-forge/maker-dmg", "platforms": ["darwin"] },
    { "name": "@electron-forge/maker-deb", "platforms": ["linux"] },
    { "name": "@electron-forge/maker-rpm", "platforms": ["linux"] },
    { "name": "@electron-forge/maker-zip", "platforms": ["darwin", "linux"] }
  ],
  "plugins": [
    "@electron-forge/plugin-vite",      // Vite integration
    "@electron-forge/plugin-fuses",     // Electron fuses
    "@electron-forge/plugin-auto-unpack-natives" // Native modules
  ]
}
```

### Vite Configuration
- **Main entry**: `.vite/build/main.js`
- **Renderer**: `.vite/build/index-*.js`
- **Preload**: `.vite/build/preload.js`
- **Workers**: `.vite/build/worker.js`

## Linux Porting Requirements

### 1. Native Binary Compilation
**Need**: Linux x64/ARM64 build of `codex` Rust binary
```bash
# Hypothetical build process for Rust core:
cd codex-core
cargo build --release --target x86_64-unknown-linux-gnu
# or
cargo build --release --target aarch64-unknown-linux-gnu
```

### 2. Native Module Rebuild
```bash
# Rebuild for Linux
cd electron-app
npm rebuild better-sqlite3 --target=linux --arch=x64
npm rebuild node-pty --target=linux --arch=x64
```

### 3. macOS-Specific Replacements

| macOS Component | Linux Replacement |
|-----------------|-------------------|
| sparkle.node | electron-updater |
| electron-liquid-glass | CSS backdrop-filter or remove |
| Seatbelt sandbox | Landlock + seccomp |
| .app bundle | .deb/.rpm/AppImage |
| DMG installer | AppImage/flatpak/snap |

### 4. Forge Config for Linux
```javascript
// forge.config.js
module.exports = {
  makers: [
    {
      name: '@electron-forge/maker-deb',
      config: {
        options: {
          maintainer: 'OpenAI',
          homepage: 'https://openai.com/codex'
        }
      }
    },
    {
      name: '@electron-forge/maker-rpm',
      config: {}
    },
    {
      name: '@electron-forge/maker-zip',
      platforms: ['linux']
    }
  ]
};
```

### 5. Sandboxing for Linux
The Rust CLI already implements Landlock+seccomp:
- Landlock LSM for filesystem access control
- seccomp-bpf for syscall filtering
- Required: `codex-linux-sandbox` helper binary

## Reverse Engineering Tools Used

1. **7z**: DMG extraction
2. **asar**: Node app archive extraction
3. **file**: Binary type identification
4. **strings**: String extraction from binaries
5. **grep/ripgrep**: Pattern matching
6. **read/plist**: Info.plist parsing

## Findings Summary

### What's Already Linux-Ready
- ✅ Electron Forge makers for Linux
- ✅ Rust CLI has Linux sandboxing code
- ✅ Node modules support Linux (just need rebuild)
- ✅ Web-based UI is platform-agnostic

### What Needs Work
- ❌ Rust `codex` binary only compiled for macOS ARM64
- ❌ Native modules need recompilation
- ❌ macOS auto-updater needs replacement
- ❌ UI glass effects need Linux alternative
- ❌ No official Linux releases yet

### Estimated Effort for Linux Port
- **Easy**: Native module rebuilds, Forge config
- **Medium**: UI polish (remove macOS-specific effects)
- **Hard**: Obtaining/compiling Rust `codex` binary for Linux
- **Unknown**: Full protocol compatibility testing

## Conclusion

Codex is a sophisticated Electron+Rust application with:
- Clean separation between UI (React) and core (Rust)
- Existing Linux support in the protocol/sandboxing layer
- Build infrastructure already configured for Linux
- Only blocker is the platform-specific Rust binary compilation

**Path to Linux**: Either OpenAI releases official Linux builds, or the community reverse-engineers the protocol enough to build a compatible core.
