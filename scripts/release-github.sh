#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

VERSION="${1:-${VERSION:-}}"
ARCH="${ALEXOS_ARCHITECTURE:-amd64}"
ISO="dist/alexOS-${ARCH}.iso"
CHECKSUM="${ISO}.sha256"

usage() {
  cat <<'EOF'
Usage:
  VERSION=v0.1.0 make release
  ./scripts/release-github.sh v0.1.0
EOF
}

if [[ -z "${VERSION}" ]]; then
  usage >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated." >&2
  exit 1
fi

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
if [[ -z "${repo}" ]]; then
  echo "No GitHub repo is configured for this checkout." >&2
  exit 1
fi

if [[ ! -f "${ISO}" ]]; then
  echo "ISO not found: ${ISO}" >&2
  echo "Build it first with: ALEXOS_VERSION=${VERSION} ALEXOS_UPDATE_REPO=${repo} make iso" >&2
  exit 1
fi

mkdir -p dist
if [[ ! -f "${CHECKSUM}" || -w "${CHECKSUM}" ]]; then
  (
    cd dist
    sha256sum "$(basename "${ISO}")" > "$(basename "${CHECKSUM}")"
  )
else
  echo "Using existing checksum: ${CHECKSUM}"
fi

title="AlexOS ${VERSION}"
notes="AlexOS ${VERSION}

Fast updater source repo: https://github.com/${repo}

Verify:
  sha256sum -c $(basename "${CHECKSUM}")"

if gh release view "${VERSION}" >/dev/null 2>&1; then
  gh release upload "${VERSION}" "${ISO}" "${CHECKSUM}" --clobber
else
  gh release create "${VERSION}" "${ISO}" "${CHECKSUM}" \
    --title "${title}" \
    --notes "${notes}" \
    --latest
fi

echo "Release ready: https://github.com/${repo}/releases/tag/${VERSION}"
