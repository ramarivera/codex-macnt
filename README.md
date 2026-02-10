# Codex Linux

Build a Linux runnable Codex package from the official macOS DMG.

This repo is intentionally minimal and orchestration runs through `mise` tasks (`codex:*`).

## Requirements

- `mise`
- Docker (or Podman with Docker CLI compatibility)
- Optional for GUI runtime: `electron` on host (`npm install -g electron`)

`mise` installs/activates the required toolchain for the tasks (for example `node` and `jq`), so no separate manual Node setup is required.

## Build

Build (full pipeline):

```nu
mise run codex:build
```

What the script does:

1. Builds a container image.
2. Extracts the Codex DMG and app bundle in container.
3. Builds the Rust CLI in container.
4. Rebuilds native Node modules on host for Electron ABI compatibility.
5. Packages a single `Codex.AppImage` in this directory.
6. Writes `versions.json` with app and CLI versions.

## Build tasks

- `mise run codex:docker-build`
- `mise run codex:docker-run`
- `mise run codex:prepare-bundle`
- `mise run codex:rebuild-native`
- `mise run codex:package-appimage`
- `mise run codex:versions`
- `mise run codex:build` (full pipeline)
- `mise run codex:release` (full build + GitHub release)

## Output

After success, you get exactly one distributable artifact here:

- `./Codex.AppImage`
- `./versions.json` (tracks `app` and `cli` versions)

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
with-env { ENABLE_LINUX_UI_POLISH: "0" } { mise run codex:build }
```

Force a specific `openai/codex` ref (branch/tag/commit):

```nu
with-env { CODEX_GIT_REF: "main" } { mise run codex:build }
```

Default behavior is a pinned known-good ref (`rust-v0.99.0-alpha.16`). Override with `CODEX_GIT_REF` if you want another ref.

## Troubleshooting

- `docker: command not found`: install Docker/Podman Docker CLI first.
- GUI says Electron is missing: install with `npm install -g electron`.
- Build issues with upstream ref: pin `CODEX_GIT_REF` to a known good tag/commit.

## Release automation

Use `mise run codex:release` to:

1. Build `Codex.AppImage`.
2. Detect app version from AppImage package metadata.
3. Detect CLI version via `./Codex.AppImage --cli --version`.
4. Update `versions.json` with both versions.
5. Create or update a GitHub release with `gh` using tag `v<app-version>`.

Run:

```nu
mise run codex:release
```

## Nushell compatibility fallback

If you use Bash/Zsh, equivalent env-var syntax is:

```bash
ENABLE_LINUX_UI_POLISH=0 mise run codex:build
CODEX_GIT_REF=main mise run codex:build
```

## Disclaimer

This project was built end-to-end using the Codex app and Codex 5.3.

This is an unofficial community project and is not affiliated with, endorsed by, or sponsored by OpenAI, ChatGPT, or Codex.
