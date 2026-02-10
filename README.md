# Codex Linux (Minimal)

This repo builds a Linux-usable Codex bundle from the official macOS DMG.

## What you run

Use a single orchestrator script:

```bash
./install-codex-linux.sh
```

The script will:
- Build a Docker image
- Run extraction/build steps inside the container
- Copy the app to `./output/codex-linux`
- Rebuild native modules on host for Electron ABI compatibility

## Output

- App bundle: `./output/codex-linux/`
- CLI binary: `./output/codex`

Run GUI:

```bash
./output/codex-linux/codex-linux.sh
```

Run CLI:

```bash
./output/codex --version
```

## Optional flags

- Disable Linux UI polish injection:

```bash
ENABLE_LINUX_UI_POLISH=0 ./install-codex-linux.sh
```

## Kept files

- `README.md`
- `AGENTS.md`
- `Dockerfile`
- `docker-compose.yml`
- `install-codex-linux.sh`
