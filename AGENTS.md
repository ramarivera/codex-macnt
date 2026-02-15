# Agent Instructions: Codex Linux 🛠️

## Quick Reference

- Build: `mise run codex:build`
- Outputs: `./Codex.AppImage`, `./versions.json`
- Release: `mise run codex:release` (requires `gh auth login`)
- Orchestration: `mise.toml` (`codex:*` tasks)
- Key knobs: `CODEX_DMG_URL`, `CODEX_SKIP_RUST_BUILD`, `CODEX_PREBUILT_CLI_URL`, `CODEX_GIT_REF`, `ENABLE_LINUX_UI_POLISH`

## Project Overview

This repo ports the Codex desktop app to Linux by:
1. Extracting UI/resources from the official macOS DMG
2. Injecting a Linux Codex CLI binary (prebuilt by default, optional source build)
3. Packaging a runnable Linux AppImage

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
│  ├─ Runs `mise` tasks                │
│  ├─ Rebuilds native Node modules     │
│  └─ Produces `Codex.AppImage`        │
├─────────────────────────────────────┤
│  Rust Build                          │
│  ├─ Default: download prebuilt CLI   │
│  └─ Optional: cargo build in container│
├─────────────────────────────────────┤
│  Assembly                            │
│  ├─ DMG → IMG → extract              │
│  ├─ asar extract → app_unpacked/     │
│  ├─ inject CLI into app bundle       │
│  └─ package AppImage                 │
└─────────────────────────────────────┘
```

## Key Files

| File | Purpose |
|------|---------|
| `mise.toml` | Main build/release orchestration via `codex:*` tasks |
| `Dockerfile` | Builder container environment |
| `.github/workflows/build-release.yml` | CI release pipeline (Linux AppImage + Windows installer artifacts) |
| `ui-design-overrides.json` | Pinned Linux UI polish overrides (used by `codex:build`) |
| `installer/` | Packaging/install glue (AppImage/desktop integration pieces) |

## Common Issues

### "resources/codex: No such file or directory"
**Cause:** `mkdir -p resources` missing before copy
**Fix:** Add directory creation step

### "Can't open as archive" (DMG)
**Cause:** 7z cannot read DMG directly
**Fix:** Use `dmg2img` to convert DMG→IMG first

### Docker cache issues
**Cause:** COPY layer cached old script version
**Fix:** `docker build --no-cache` or change Dockerfile to invalidate

## Build Process

Preferred entrypoint is the `mise` pipeline:

1. `mise run codex:build`
2. Run `./Codex.AppImage` (GUI) or `./Codex.AppImage --cli --help` (CLI)

Internals (high-level):

1. Download `Codex.dmg` from `CODEX_DMG_URL` (inside container).
2. `dmg2img` and `7z` extract, then unpack `app.asar` into `app_unpacked/`.
3. Inject the `codex` CLI into `resources/` and `resources/bin/`.
4. Optionally apply Linux UI polish when `ENABLE_LINUX_UI_POLISH=1`.
5. Package `Codex.AppImage`, then generate `versions.json`.

## Testing Checklist

- [ ] `mise run codex:build` completes
- [ ] `./Codex.AppImage --cli --version` runs successfully
- [ ] `versions.json` exists and contains non-empty `app` and `cli` fields
- [ ] GUI launches (`./Codex.AppImage`) when testing UI/runtime changes
- [ ] If changing Rust build path (`CODEX_SKIP_RUST_BUILD=0`): container `cargo build` succeeds

## Docker Notes

Local builds use Docker via `mise` (see `mise.toml`).

**Do not use privileged mode if possible.** Use SYS_ADMIN cap instead for unprivileged DMG operations.

## Dependencies

Host requirements:
- `mise`
- Docker (or Podman with Docker CLI compatibility)
- Optional: `gh` (for `codex:release`)

Builder image dependencies (Dockerfile installs these):
- `dmg2img`, `p7zip`, build toolchain, Node/npm, Rust toolchain (when building from source)

## Reverse Engineering Notes

Keep reverse-engineering notes out of this repo unless they are safe to publish.
