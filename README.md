# Codex Linux

Build a Linux runnable Codex package from the official macOS DMG.

This repo is intentionally minimal and uses one orchestration script: `install-codex-linux.sh`.

## Requirements

- Docker (or Podman with Docker CLI compatibility)
- `node` and `npm` on the host (used for native module rebuild)
- `curl` or `wget` (to download AppImage tooling)
- Optional for GUI runtime: `electron` on host (`npm install -g electron`)

## Build

From the same directory as `install-codex-linux.sh`:

```nu
./install-codex-linux.sh
```

What the script does:

1. Builds a container image.
2. Extracts the Codex DMG and app bundle in container.
3. Builds the Rust CLI in container.
4. Rebuilds native Node modules on host for Electron ABI compatibility.
5. Packages a single `Codex.AppImage` in this directory.

## Output

After success, you get exactly one distributable artifact here:

- `./Codex.AppImage`
- `./CODEX_APP_VERSION` (app package version from Codex bundle)
- `./CODEX_CLI_VERSION` (embedded CLI version)

## Run

GUI mode:

```nu
./Codex.AppImage
```

CLI mode through AppImage:

```nu
./Codex.AppImage --cli --help
./Codex.AppImage --cli --version
```

## Useful options

Disable Linux UI polish during build:

```nu
with-env { ENABLE_LINUX_UI_POLISH: "0" } { ./install-codex-linux.sh }
```

Force a specific `openai/codex` ref (branch/tag/commit):

```nu
with-env { CODEX_GIT_REF: "main" } { ./install-codex-linux.sh }
```

Default behavior is `CODEX_GIT_REF=latest-tag`, which selects the newest buildable tag.

## Troubleshooting

- `docker: command not found`: install Docker/Podman Docker CLI first.
- GUI says Electron is missing: install with `npm install -g electron`.
- Build issues with upstream ref: pin `CODEX_GIT_REF` to a known good tag/commit.

## Release automation

Use `scripts/release-appimage.sh` to:

1. Build `Codex.AppImage`.
2. Detect app version from AppImage package metadata.
3. Detect CLI version via `./Codex.AppImage --cli --version`.
4. Update `CODEX_APP_VERSION` and `CODEX_CLI_VERSION`.
5. Create or update a GitHub release with `gh` using tag `v<app-version>`.

Run:

```nu
./scripts/release-appimage.sh
```

## Nushell compatibility fallback

If you use Bash/Zsh, equivalent env-var syntax is:

```bash
ENABLE_LINUX_UI_POLISH=0 ./install-codex-linux.sh
CODEX_GIT_REF=main ./install-codex-linux.sh
```
