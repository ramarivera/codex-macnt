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
- `mise run codex:ui:extract` (extract built UI assets)
- `mise run codex:ui:capture` (run AppImage and capture live UI via `agent-browser`)
- `mise run codex:ui:design` (Claude CLI generates `ui-design-overrides.candidate.json`)
- `mise run codex:ui:pin` (promote candidate to pinned `ui-design-overrides.json`)
- `mise run codex:ui:loop` (design candidate + print next steps)

## Output

After success, you get these artifacts locally from the Linux build path:

- `./Codex.AppImage`
- `./versions.json` (tracks `app` and `cli` versions)

The GitHub release workflow also publishes:

- `Codex-Setup-Windows-x64.exe` (NSIS installer)
- `Codex-x86_64.AppImage` (portable Linux AppImage)

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

## Claude design loop (terminal)

To co-design Linux polish with Claude Code CLI from terminal:

```nu
mise run codex:ui:loop
```

This flow:
1. Extracts AppImage UI assets into `.ui-inspect/`.
2. Runs the AppImage and captures live UI with `agent-browser` (`.ui-inspect/codex-current.png`, `.ui-inspect/codex-snapshot.json`).
3. Asks `claude` CLI to produce candidate overrides in `ui-design-overrides.candidate.json`.
4. Does not auto-apply anything (keeps output deterministic).

Apply candidate intentionally:

```nu
mise run codex:ui:pin
mise run codex:build
```

`codex:build` always uses pinned `ui-design-overrides.json`, so the UI does not change randomly between runs.

## Nushell compatibility fallback

If you use Bash/Zsh, equivalent env-var syntax is:

```bash
ENABLE_LINUX_UI_POLISH=0 mise run codex:build
CODEX_GIT_REF=main mise run codex:build
```

## Disclaimer

This project was built end-to-end using the Codex app and Codex 5.3.

This is an unofficial community project.

- Project source is a hobbyist community build and reverse-engineering effort.
- Not affiliated with, endorsed by, sponsored by, or officially supported by OpenAI, ChatGPT, or Codex.
- Windows installer and Linux packaging are community-maintained adaptations and may differ from official OpenAI releases.
- Use at your own risk; verify checksums and behavior before production use.
- If you report issues, use this repository and include platform/version details.
