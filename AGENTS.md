# Agent Instructions: Codex Linux

## Project Overview

This repository ports OpenAI's Codex (macOS-only desktop app) to Linux by:
1. Extracting resources from the official macOS DMG
2. Building the Rust CLI for Linux target
3. Assembling a working Linux application

## Critical Rules

### DO NOT
- Commit broken code without testing
- Assume Docker layers are fresh (use --no-cache when testing)
- Edit files without reading them first
- Use `sudo` in scripts (users run as themselves)

### ALWAYS
- Test scripts before committing
- Verify file paths exist before copying
- Check Docker cache invalidation
- Handle errors gracefully

## Architecture

```
┌─────────────────────────────────────┐
│  Host System (Linux)                │
│  ├─ Downloads Codex DMG              │
│  ├─ dmg2img → 7z extract             │
│  ├─ asar extract → app_unpacked/     │
│  └─ Runs install script              │
├─────────────────────────────────────┤
│  Rust Build                          │
│  ├─ Clones openai/codex              │
│  ├─ cargo build --release            │
│  └─ Outputs: codex binary            │
├─────────────────────────────────────┤
│  Assembly                            │
│  ├─ mkdir -p resources               │
│  ├─ cp codex resources/              │
│  ├─ rm macOS-only files              │
│  └─ Install to ~/.local/bin          │
└─────────────────────────────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| `mise.toml` | Main build/release orchestration via `codex:*` tasks |
| `Dockerfile` | Container environment (optional) |

## Common Issues

### "resources/codex: No such file or directory"
**Cause:** `mkdir -p resources` missing before copy
**Fix:** Add directory creation step

### "Can't open as archive" (DMG)
**Cause:** 7z cannot read DMG directly
**Fix:** Use `dmg2img` to convert DMG→IMG first

### "x86_64-linux-musl-gcc: not found"
**Cause:** Trying to build with musl target, no cross compiler
**Fix:** Fallback to native target or install musl-tools

### Docker cache issues
**Cause:** COPY layer cached old script version
**Fix:** `docker build --no-cache` or change Dockerfile to invalidate

## Build Process

1. **Download**: `curl -o Codex.dmg $DMG_URL`
2. **Extract DMG**: `dmg2img Codex.dmg Codex.img && 7z x Codex.img`
3. **Extract ASAR**: `asar extract app.asar app_unpacked/`
4. **Build Rust**: `cargo build --release --bin codex`
5. **Assemble**: Copy binary, remove macOS files, create launcher
6. **Install**: `cp codex ~/.local/bin/`

## Testing Checklist

- [ ] DMG downloads successfully
- [ ] dmg2img converts without error
- [ ] 7z extracts IMG to get .app bundle
- [ ] ASAR extracts to app_unpacked/
- [ ] Rust compiles (may fallback from musl to native)
- [ ] resources/ directory exists before copy
- [ ] codex binary installed to PATH
- [ ] Launcher script created

## Docker Notes

Local builds use Docker via `mise` (see `mise.toml`).

**Do not use privileged mode if possible.** Use SYS_ADMIN cap instead for unprivileged DMG operations.

## Dependencies

System packages:
- p7zip-full
- dmg2img
- build-essential
- libssl-dev
- pkg-config

Rust/cargo (via rustup)
Node.js + npm

## Reverse Engineering Notes

Keep reverse-engineering notes out of this repo unless they are safe to publish.
