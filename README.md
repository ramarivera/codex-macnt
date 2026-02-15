# Codex Linux (Unofficial)

Build a Linux-runnable Codex desktop app (`Codex.AppImage`) from the official macOS DMG.

- Output: `./Codex.AppImage` + `./versions.json`
- Orchestration: `mise` tasks (`codex:*`)
- Status: community project, not affiliated with OpenAI

## Quick Start 🚀

```nu
mise run codex:build
./Codex.AppImage
```

## Requirements

- `mise`
- Docker (or Podman with Docker CLI compatibility)
- Optional: `gh` (needed for `mise run codex:release`)
- Optional: `electron` on host (`npm install -g electron`) for some dev/runtime flows

`mise` installs/activates the toolchain for tasks (notably `node` and `jq`), so there is no separate Node setup step.

## How It Works (Build Pipeline)

`mise run codex:build` runs a deterministic pipeline:

1. Build a `codex-builder` container image (cached after first run).
2. In container: download DMG (`CODEX_DMG_URL`), convert via `dmg2img`, extract app bundle, unpack `app.asar`.
3. Inject the Codex CLI binary into the unpacked app:
   - Default: download a prebuilt CLI (`CODEX_SKIP_RUST_BUILD=1` + `CODEX_PREBUILT_CLI_URL`).
   - Optional: build from source by setting `CODEX_SKIP_RUST_BUILD=0`.
4. On host: rebuild native Node modules for Electron ABI compatibility.
5. Package `Codex.AppImage` into the repo root.
6. Write `versions.json` (app version from AppImage `package.json`, CLI version from `--cli --version`).

## Configuration ⚙️

Environment variables (defaults live in `mise.toml`):

| Var | Default | Notes |
|-----|---------|-------|
| `CODEX_DMG_URL` | official DMG URL | Download source for the macOS app bundle. |
| `CODEX_GIT_REF` | `rust-v0.102.0-alpha.7` | Only used when building the CLI from source. Use `latest-tag` to auto-pick the newest buildable tag. |
| `CODEX_SKIP_RUST_BUILD` | `1` | `1` downloads a prebuilt CLI; `0` builds from `openai/codex` in the container. |
| `CODEX_PREBUILT_CLI_URL` | GitHub release tarball | Where to fetch the prebuilt CLI when `CODEX_SKIP_RUST_BUILD=1`. |
| `CODEX_PREBUILT_SANDBOX_URL` | unset | Optional: fetch a prebuilt `codex-linux-sandbox` binary. |
| `ENABLE_LINUX_UI_POLISH` | `1` | Toggle CSS-based UI polish injection at build time. |
| `WORKDIR` | `~/.cache/codex-linux-port` | Build cache and docker bind mount workspace. |

Examples (Nushell):

```nu
# Disable UI polish injection
with-env { ENABLE_LINUX_UI_POLISH: "0" } { mise run codex:build }

# Build CLI from source instead of downloading a prebuilt binary
with-env { CODEX_SKIP_RUST_BUILD: "0" } { mise run codex:build }

# Try the newest buildable upstream tag (can break; best-effort)
with-env { CODEX_GIT_REF: "latest-tag", CODEX_SKIP_RUST_BUILD: "0" } { mise run codex:build }
```

## Tasks (Most Used)

- `mise run codex:build`: build `Codex.AppImage` + `versions.json`
- `mise run codex:release`: run build and publish/update a GitHub release (requires `gh auth login`)
- `mise run codex:cleanup`: delete build caches under `WORKDIR`
- `mise run codex:ui:extract`: extract UI assets from `Codex.AppImage` into `.ui-inspect/`
- `mise run codex:ui:capture`: run AppImage and capture a live screenshot via `agent-browser`
- `mise run codex:ui:loop`: generate `ui-design-overrides.candidate.json` and print next steps
- `mise run codex:ui:pin`: promote candidate overrides to pinned `ui-design-overrides.json`
- `mise run codex:ui:iterate`: fast loop to apply overrides and re-capture a screenshot

## Run

GUI mode:

```nu
./Codex.AppImage
```

CLI mode (through AppImage):

```nu
./Codex.AppImage --cli --help
./Codex.AppImage --cli --version
```

## Troubleshooting 🧯

- `docker: command not found`: install Docker (or Podman with Docker CLI compatibility).
- `❌ Could not locate app.asar`: the DMG extraction did not produce an app bundle; re-run and inspect `WORKDIR/docker-output` contents.
- `Selected ref ... is not buildable`: set `CODEX_GIT_REF` to a known-good tag/commit, or use the default prebuilt CLI path (`CODEX_SKIP_RUST_BUILD=1`).
- GUI says Electron is missing: install with `npm install -g electron`.

## Shell Notes

If you use Bash/Zsh, env-var examples become:

```bash
ENABLE_LINUX_UI_POLISH=0 mise run codex:build
CODEX_SKIP_RUST_BUILD=0 mise run codex:build
CODEX_GIT_REF=latest-tag CODEX_SKIP_RUST_BUILD=0 mise run codex:build
```

## Disclaimer

This is an unofficial community project:

- Not affiliated with, endorsed by, sponsored by, or officially supported by OpenAI, ChatGPT, or Codex.
- Linux packaging and Windows installer artifacts are community-maintained and may differ from official releases.
- Use at your own risk; verify checksums and behavior before trusting outputs.
