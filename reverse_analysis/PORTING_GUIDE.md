# Codex Linux Porting Guide

## Quick Start for Linux Build

### Prerequisites
```bash
# Install dependencies
npm install -g pnpm electron-forge

# Install Linux build tools
sudo apt-get install dpkg rpm fakeroot  # Debian/Ubuntu
sudo dnf install dpkg rpmdevtools       # Fedora
```

### Build Steps

1. **Get the source** (hypothetical - need OpenAI to release it)
   ```bash
   git clone https://github.com/openai/codex-desktop
   cd codex-desktop
   ```

2. **Install dependencies**
   ```bash
   pnpm install
   ```

3. **Rebuild native modules for Linux**
   ```bash
   pnpm rebuild better-sqlite3
   pnpm rebuild node-pty
   # Skip sparkle and liquid-glass for Linux
   ```

4. **Build Rust CLI for Linux** (need source or compatible binary)
   ```bash
   # If Rust source available:
   cd codex-core
   cargo build --release --target x86_64-unknown-linux-gnu
   cp target/release/codex ../electron-app/resources/
   ```

5. **Build Electron app for Linux**
   ```bash
   cd electron-app
   pnpm run make -- --platform=linux --arch=x64
   # or
   pnpm run make -- --platform=linux --arch=arm64
   ```

### Output
- `out/make/deb/x64/codex_*.deb` - Debian/Ubuntu package
- `out/make/rpm/x64/codex_*.rpm` - Fedora/RHEL package
- `out/make/zip/linux/x64/codex-linux-x64.zip` - Portable zip

## Platform-Specific Notes

### Native Modules Status

| Module | macOS | Linux Status | Action |
|--------|-------|--------------|--------|
| better-sqlite3 | ✅ ARM64 | ⚠️ Needs rebuild | `npm rebuild` |
| node-pty | ✅ ARM64 | ⚠️ Needs rebuild | `npm rebuild` |
| sparkle | ✅ Native | ❌ Not needed | Remove/replace |
| liquid-glass | ✅ Native | ❌ Not needed | Remove |

### Sandboxing

**macOS (Current)**:
- Seatbelt (app sandbox)
- Sparkle auto-updater

**Linux (Target)**:
- Landlock LSM (filesystem)
- seccomp-bpf (syscalls)
- electron-updater (auto-update)

### UI Considerations

Remove or replace these macOS-specific UI elements:
1. **Liquid glass effects** - Use CSS `backdrop-filter` or solid colors
2. **Traffic light buttons** - Implement custom window controls
3. **Native menus** - Use Electron's `Menu` API (cross-platform)

## Protocol Compatibility

The JSON-RPC protocol between Electron and Rust core is platform-agnostic.
Key endpoints identified:

- `Initialize` - App initialization
- `ThreadStart` - New conversation
- `SendUserTurn` - Send message
- `ClientRequest` - Various client ops
- `McpServer*` - MCP tool management

## Testing Checklist

- [ ] App launches on Linux
- [ ] Can authenticate (ChatGPT or API key)
- [ ] Terminal PTY works
- [ ] SQLite persistence works
- [ ] Sandboxing restricts filesystem access
- [ ] Auto-updater works (if implemented)
- [ ] All IDE integrations functional
