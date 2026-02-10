#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APPIMAGE_PATH="${REPO_DIR}/Codex.AppImage"
VERSIONS_FILE="${REPO_DIR}/versions.json"

echo "==> Building Codex AppImage"
"${REPO_DIR}/install-codex-linux.sh"

if [[ ! -x "${APPIMAGE_PATH}" ]]; then
  echo "❌ AppImage not found at ${APPIMAGE_PATH}" >&2
  exit 1
fi

echo "==> Detecting CLI version"
version_output="$(${APPIMAGE_PATH} --cli --version)"
version="$(awk '{print $2}' <<<"${version_output}")"

if [[ -z "${version}" ]]; then
  echo "❌ Failed to parse version from: ${version_output}" >&2
  exit 1
fi

echo "==> Detecting app version"
if ! command -v node >/dev/null 2>&1; then
  echo "❌ node is required to read app version from AppImage" >&2
  exit 1
fi

extract_tmp="$(mktemp -d)"
cleanup() {
  rm -rf "${extract_tmp}"
}
trap cleanup EXIT

cp "${APPIMAGE_PATH}" "${extract_tmp}/Codex.AppImage"
(cd "${extract_tmp}" && ./Codex.AppImage --appimage-extract >/dev/null 2>&1)
app_version="$(node -p "require('${extract_tmp}/squashfs-root/usr/share/codex/package.json').version" 2>/dev/null || true)"

if [[ -z "${app_version}" ]]; then
  echo "❌ Failed to detect app version from AppImage package.json" >&2
  exit 1
fi

cat > "${VERSIONS_FILE}" <<EOF
{
  "app": "${app_version}",
  "cli": "${version}"
}
EOF
echo "Versions written to ${VERSIONS_FILE}: app=${app_version}, cli=${version}"

if ! command -v gh >/dev/null 2>&1; then
  echo "❌ GitHub CLI (gh) not found" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

tag="v${app_version}"
title="Codex AppImage ${app_version}"
notes="Automated AppImage release for Codex app ${app_version} (CLI ${version})."

echo "==> Publishing GitHub release ${tag}"
if gh release view "${tag}" >/dev/null 2>&1; then
  gh release upload "${tag}" "${APPIMAGE_PATH}" --clobber
  gh release edit "${tag}" --title "${title}" --notes "${notes}"
else
  gh release create "${tag}" "${APPIMAGE_PATH}" --title "${title}" --notes "${notes}"
fi

echo "✅ Release published: ${tag}"
