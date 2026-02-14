#!/usr/bin/env bash
set -euo pipefail

: "${CODEX_VM_GUEST_WORKDIR:?Missing CODEX_VM_GUEST_WORKDIR}"
: "${CODEX_VM_CODEX_GIT_REF:=rust-v0.102.0-alpha.5}"
: "${CODEX_VM_CODEX_DMG_URL:=https://persistent.oaistatic.com/codex-app-prod/Codex.dmg}"
: "${CODEX_VM_ENABLE_LINUX_UI_POLISH:=1}"

WORKDIR="$CODEX_VM_GUEST_WORKDIR"
OUTPUT_DIR="${CODEX_VM_OUTPUT_DIR:-$WORKDIR/.codex-vm-output}"
RUN_ID="${CODEX_VM_RUN_ID:-unknown}"

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

if ! command -v mise >/dev/null 2>&1; then
  echo "mise not found; install https://mise.jdx.dev" >&2
  exit 1
fi

export CODEX_DMG_URL="$CODEX_VM_CODEX_DMG_URL"
export CODEX_GIT_REF="$CODEX_VM_CODEX_GIT_REF"
export ENABLE_LINUX_UI_POLISH="$CODEX_VM_ENABLE_LINUX_UI_POLISH"

cd "$WORKDIR"

echo "Starting Linux Codex build in $WORKDIR"
mise run codex:build

if [[ -f "$WORKDIR/Codex.AppImage" ]]; then
  cp "$WORKDIR/Codex.AppImage" "$OUTPUT_DIR/Codex.AppImage"
fi

if [[ -f "$WORKDIR/versions.json" ]]; then
  cp "$WORKDIR/versions.json" "$OUTPUT_DIR/versions.json"
fi

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

if [[ -f "$OUTPUT_DIR/Codex.AppImage" && -f "$OUTPUT_DIR/versions.json" ]]; then
  echo "Linux guest build complete: $OUTPUT_DIR"
  exit 0
fi

echo "Linux build did not produce expected artifacts in $WORKDIR" >&2
exit 1
