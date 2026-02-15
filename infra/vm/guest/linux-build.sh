#!/usr/bin/env bash
set -euo pipefail

: "${CODEX_VM_GUEST_WORKDIR:?Missing CODEX_VM_GUEST_WORKDIR}"
: "${CODEX_VM_CODEX_GIT_REF:=rust-v0.102.0-alpha.5}"
: "${CODEX_VM_CODEX_DMG_URL:=https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
: "${CODEX_VM_ENABLE_LINUX_UI_POLISH:=1}"
: "${CODEX_SKIP_RUST_BUILD:=0}"
: "${CODEX_SKIP_REBUILD_NATIVE:=0}"
: "${CODEX_PREBUILT_CLI_URL:=}"
: "${CODEX_PREBUILT_SANDBOX_URL:=}"

WORKDIR="$CODEX_VM_GUEST_WORKDIR"
OUTPUT_DIR="${CODEX_VM_OUTPUT_DIR:-$WORKDIR/.codex-vm-output}"
RUN_ID="${CODEX_VM_RUN_ID:-unknown}"
SELF="${BASH_SOURCE[0]}"

mkdir -p "$OUTPUT_DIR"

if [[ ! -d "$WORKDIR" ]]; then
  echo "Missing guest work directory: $WORKDIR" >&2
  exit 1
fi

cd "$WORKDIR"

if [[ ! -f mise.toml ]]; then
  echo "mise.toml not found in $WORKDIR" >&2
  exit 1
fi

export PATH="$HOME/.local/bin:$PATH"
export MISE_FETCH_REMOTE_VERSIONS_TIMEOUT="${MISE_FETCH_REMOTE_VERSIONS_TIMEOUT:-120}"
export MISE_LOCKED="${MISE_LOCKED:-1}"
export MISE_HTTP_TIMEOUT="${MISE_HTTP_TIMEOUT:-300}"
if ! command -v mise >/dev/null 2>&1; then
  echo "mise not found; installing..."
  curl -fsSL https://mise.jdx.dev/install.sh | sh
  if ! command -v mise >/dev/null 2>&1; then
    echo "mise installation failed" >&2
    exit 1
  fi
fi

mise trust --all 2>/dev/null || mise trust "$WORKDIR/mise.toml" 2>/dev/null || true

export CODEX_DMG_URL="$CODEX_VM_CODEX_DMG_URL"
export CODEX_GIT_REF="$CODEX_VM_CODEX_GIT_REF"
export ENABLE_LINUX_UI_POLISH="$CODEX_VM_ENABLE_LINUX_UI_POLISH"
export CODEX_SKIP_RUST_BUILD="$CODEX_SKIP_RUST_BUILD"
export CODEX_SKIP_REBUILD_NATIVE="$CODEX_SKIP_REBUILD_NATIVE"
export CODEX_PREBUILT_CLI_URL="$CODEX_PREBUILT_CLI_URL"
export CODEX_PREBUILT_SANDBOX_URL="$CODEX_PREBUILT_SANDBOX_URL"

sudo_maybe() {
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi
  if sudo -n true >/dev/null 2>&1; then
    sudo "$@"
    return $?
  fi
  if [[ -n "${CODEX_VM_GUEST_PASSWORD:-}" ]]; then
    printf '%s\n' "$CODEX_VM_GUEST_PASSWORD" | sudo -S "$@"
    return $?
  fi
  return 1
}

ensure_dns() {
  local host="$1"
  if getent hosts "$host" >/dev/null 2>&1; then
    return 0
  fi

  sudo_maybe systemctl restart systemd-resolved >/dev/null 2>&1 || true
  if getent hosts "$host" >/dev/null 2>&1; then
    return 0
  fi

  # Prefer systemd-resolved's non-stub resolv.conf if present.
  if [[ -f /run/systemd/resolve/resolv.conf ]]; then
    sudo_maybe ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf >/dev/null 2>&1 || true
  fi
  if getent hosts "$host" >/dev/null 2>&1; then
    return 0
  fi

  # Last resort: write a static resolv.conf.
  sudo_maybe sh -c "cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF" >/dev/null 2>&1 || true
  getent hosts "$host" >/dev/null 2>&1
}

force_public_dns() {
  # VirtualBox NAT DNS (10.0.2.3) can be flaky depending on host resolver
  # configuration. Prefer known public resolvers for reproducible builds.
  if sudo_maybe resolvectl dns enp0s3 1.1.1.1 8.8.8.8 >/dev/null 2>&1; then
    sudo_maybe resolvectl domain enp0s3 '~.' >/dev/null 2>&1 || true
    sudo_maybe systemctl restart systemd-resolved >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

# Ensure docker access — bootstrap adds us to docker group but current session
# may not have picked it up yet.
if ! docker info >/dev/null 2>&1; then
  if id -nG | grep -qw docker; then
    exec sg docker -c "$(printf '%q ' bash "$SELF" "$@")"
  else
    # If docker group membership never applied (common in unattended installs),
    # try to fix it in-band and then re-exec under the docker group.
    sudo_maybe groupadd -f docker >/dev/null 2>&1 || true
    sudo_maybe usermod -aG docker "$USER" >/dev/null 2>&1 || true
    sudo_maybe chmod 666 /var/run/docker.sock >/dev/null 2>&1 || true
    exec sg docker -c "$(printf '%q ' bash "$SELF" "$@")"
  fi
fi

cd "$WORKDIR"

# DNS in fresh unattended installs can be flaky; fix it up before doing any
# network-heavy work (Docker pulls, git clones, etc).
force_public_dns || true
ensure_dns registry-1.docker.io || true
ensure_dns github.com || true
ensure_dns registry.npmjs.org || true
ensure_dns persistent.oaistatic.com || true

echo "Starting Linux Codex build in $WORKDIR"

BUILD_LOG="$OUTPUT_DIR/build.log"
mise run codex:build 2>&1 | tee "$BUILD_LOG"

MANIFEST="$OUTPUT_DIR/manifest.json"
cat > "$MANIFEST" <<EOF_JSON
{
  "platform": "linux",
  "host": "$(hostname)",
  "workspace": "$WORKDIR",
  "run_id": "${RUN_ID}",
  "codex_git_ref": "$CODEX_VM_CODEX_GIT_REF",
  "code_dmg_url": "$CODEX_VM_CODEX_DMG_URL",
  "artifact": "Codex.AppImage"
}
EOF_JSON

if [[ -f "$WORKDIR/Codex.AppImage" ]]; then
  cp "$WORKDIR/Codex.AppImage" "$OUTPUT_DIR/Codex.AppImage"
fi

if [[ -f "$WORKDIR/versions.json" ]]; then
  cp "$WORKDIR/versions.json" "$OUTPUT_DIR/versions.json"
fi

if [[ -f "$OUTPUT_DIR/Codex.AppImage" && -f "$OUTPUT_DIR/versions.json" ]]; then
  echo "Linux guest build complete: $OUTPUT_DIR"
  exit 0
fi

echo "Linux build did not produce expected artifacts in $WORKDIR" >&2
exit 1
