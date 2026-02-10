# Codex for Linux 🐧

**One-command installer to get OpenAI's Codex working on Linux!**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## 🚀 Quick Install (One Command)

```bash
curl -fsSL https://raw.githubusercontent.com/ramarivera/codex-linux/master/install-codex-linux.sh | bash
```

That's it! This single command will:
1. Download the macOS Codex app from OpenAI
2. Extract the Electron shell and resources
3. Clone and compile the Rust CLI core for Linux
4. Rebuild native modules for Linux
5. Install everything to `~/.local/bin/`
6. Create a desktop entry

## 📋 What You Get

After installation, you'll have:

- ✅ `codex` command in your PATH (CLI mode - works immediately)
- ✅ GUI launcher (if you install Electron: `npm install -g electron`)
- ✅ Desktop entry for your app menu
- ✅ Full Linux sandboxing (Landlock + seccomp)
- ✅ All Codex features: AI coding, terminal, file editing, git integration

## 🎮 Usage

### CLI Mode (Recommended)
```bash
# Login first
codex login

# Or with API key
printenv OPENAI_API_KEY | codex login --with-api-key

# Start coding
codex "Implement a Python web scraper"

# See all options
codex --help
```

### GUI Mode
```bash
# Run the GUI (requires Electron)
~/.cache/codex-linux-port/app_unpacked/codex-linux.sh
```

Or find **Codex** in your applications menu!

## 🔧 Requirements

- **OS**: Linux (x86_64 or aarch64)
- **RAM**: 4GB+ recommended (Rust compilation needs memory)
- **Disk**: ~2GB free space
- **Dependencies**:
  - `curl` or `wget`
  - `7z` (will auto-install if missing)
  - `rustc` and `cargo` (will be used if present, otherwise script uses Bazel)
  - `nodejs` and `npm` (for native module rebuilds)

## 🏗️ How It Works

This project bridges macOS Codex to Linux through:

1. **Resource Extraction**: Pulls the UI, icons, and web assets from the official macOS DMG
2. **Binary Compilation**: Builds the Rust CLI core from [openai/codex](https://github.com/openai/codex) repo
3. **Native Module Rebuild**: Recompiles Node.js native addons for Linux
4. **Sandbox Adaptation**: Uses Linux-native Landlock LSM + seccomp instead of macOS Seatbelt

### Architecture

```
┌─────────────────────────────────────────┐
│         Electron Shell (from DMG)       │
│         React + Vite UI                 │
├─────────────────────────────────────────┤
│         Node.js Main Process            │
│         + Rebuilt Native Modules        │
├─────────────────────────────────────────┤
│         Rust CLI (compiled for Linux)   │
│         codex-core + codex-tui          │
├─────────────────────────────────────────┤
│         Linux Sandboxing                │
│         Landlock + seccomp              │
└─────────────────────────────────────────┘
```

## 📝 Detailed Analysis

See [`reverse_analysis/`](./reverse_analysis/) for full reverse engineering details:

- [`ANALYSIS.md`](./reverse_analysis/ANALYSIS.md) - Technical deep dive
- [`PORTING_GUIDE.md`](./reverse_analysis/PORTING_GUIDE.md) - How to port Electron apps
- File structure, protocol analysis, build system breakdown

## 🔄 Updates

To update Codex to the latest version:

```bash
rm -rf ~/.cache/codex-linux-port
bash install-codex-linux.sh
```

## 🐛 Troubleshooting

### "codex: command not found"
```bash
export PATH="$HOME/.local/bin:$PATH"
# Add to ~/.bashrc or ~/.zshrc for persistence
```

### Build fails / out of memory
```bash
# Try building with fewer parallel jobs
cd ~/.cache/codex-linux-port/codex-src/codex-rs
cargo build --release --bin codex -j 2
```

### Native module errors
```bash
cd ~/.cache/codex-linux-port/app_unpacked
npm rebuild better-sqlite3
npm rebuild node-pty
```

### Missing Electron for GUI
```bash
npm install -g electron
codex-linux.sh
```

## ⚖️ Legal Notice

This is an **unofficial** port for educational purposes. All Codex branding, code, and functionality belongs to OpenAI. The original Codex CLI and app server protocol are open source (MIT license) from [github.com/openai/codex](https://github.com/openai/codex).

Use at your own risk. This is not endorsed by OpenAI.

## 🙏 Credits

- **OpenAI** for creating Codex and open-sourcing the CLI
- **Electron** team for the cross-platform framework
- **Rust** community for the excellent tooling

## 📜 License

MIT - See [LICENSE](./LICENSE) file

---

**Enjoy coding with Codex on Linux!** 🎉
