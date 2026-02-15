# Codex VM Orchestration

This directory contains a reproducible build orchestrator for running the Codex pipeline on a separate VirtualBox host via SSH.

The setup is split into:

- `config.example.toml`: runtime configuration template (copy to `~/.config/codex-vm/config.toml`).
- `codex-vm`: host-side orchestrator invoked by `mise`.
- `guest/linux-build.sh`: Linux guest entrypoint to run `mise run codex:build`.
- `guest/windows-build.ps1`: Windows guest entrypoint for Windows installer packaging.
- `remote/build-agent.sh`: Remote host script that provisions/starts VMs and executes guest builds.

## Design goals

- No host-specific secrets are committed in the repository.
- Reproducible execution using explicit config and versioned artifacts.
- Default behavior reuses VMs; set `lifecycle_mode = "recreate"` for full rebuild.

## Quick start

1. Copy the example config and edit local/private values:

```bash
mkdir -p ~/.config/codex-vm
cp infra/vm/config.example.toml ~/.config/codex-vm/config.toml
```

2. Configure SSH host, keys, VM names, workspace paths, and OVA/ISO paths.

3. Run a preflight:

```bash
mise run codex:vm:check
```

The check step also resolves VM media on the remote host:

- If `linux_base_iso` is empty, it first searches for an Ubuntu ISO candidate, then downloads `linux_iso_url` when no match is found.
- If `windows_base_iso` is empty, it searches for a Windows Server ISO on the remote host (prioritizing `~/Downloads`).

4. Run a build:

```bash
mise run codex:vm:build      # linux + windows
mise run codex:vm:linux:build
mise run codex:vm:win:build
```

Artifacts are written under:

- `infra/vm/artifacts/<run-id>/linux/Codex.AppImage`
- `infra/vm/artifacts/<run-id>/windows/Codex-Setup-Windows-x64.exe`
- `infra/vm/artifacts/<run-id>/run-manifest.json`

## Linux auth and retry contract

Linux guest provisioning now probes SSH users in a deterministic order:

- Primary configured user (`linux_guest_user`)
- Optional `guest_auth_users` list (comma-separated, e.g. `builder,ubuntu,root`)
- `ubuntu`
- `root`

The first successful user is selected and then used for:

- workspace derivation (`/home/<user>/codex-linux`)
- source sync
- build invocation
- artifact pulls

If all candidates fail on auth, the run fails once, emits candidate-level error context, then (if enabled) recreates the VM exactly once and retries:

- `retry_recreate_on_auth_failure = "1"` (default) enables one controlled recreate retry
- `retry_recreate_on_auth_failure = "0"` fails immediately

On Linux auth/build failures, debug artifacts are collected under:

- `infra/vm/artifacts/<run-id>/debug/linux/bootstrap.log` (guest bootstrap attempt output)
- `infra/vm/artifacts/<run-id>/debug/linux/auth-attempts.log`
- `infra/vm/artifacts/<run-id>/debug/linux/failure-reason.txt`
- `infra/vm/artifacts/<run-id>/debug/linux/<VirtualBox VM log files>`

## Config values

| Setting | Purpose |
|---|---|
| `host` | Remote SSH host |
| `user` | SSH username on the VM host |
| `ssh_port` | SSH port on host |
| `ssh_key` | Private key for host SSH |
| `guest_key` | Private key injected into Linux/Windows guests for build transport |
| `base_dir` | Base folder for temporary source/artifacts on host |
| `artifact_dir` | Root artifact folder on host |
| `lifecycle_mode` | `reuse` (default) or `recreate` |
| `guest_auth_users` | Optional comma-separated list override for Linux SSH probe users |
| `retry_recreate_on_auth_failure` | `1` for one Linux-auth failure recreate retry, `0` to fail fast |
| `linux_iso_url` | Ubuntu ISO URL used when `linux_base_iso` is unset and no local Ubuntu ISO is found |
| `linux_*`, `windows_*` | VM identity/capability settings |
| `local_output_dir` | Local repo path for pulled artifacts |

## Notes

- `codex-vm` is intentionally thin: it pushes the current repository to remote host, executes the remote agent, then fetches artifacts.
- `check` validates SSH reachability and required host tools.
- `CODEX_VM_*` variables can override config-file values on invocation.
- This layer is intended to complement, not replace, existing GitHub Actions releases.

## Security checklist

- Keep only `config.example.toml` tracked.
- Keep `~/.config/codex-vm/config.toml` and any VM secrets out of git.
- Do not commit host addresses, local keys, or absolute host paths.
