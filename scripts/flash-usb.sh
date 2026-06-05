#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${ALEXOS_ARCHITECTURE:-amd64}"
ISO="${ISO:-${ROOT_DIR}/dist/alexOS-${ARCH}.iso}"

if [[ "${CONFIRM:-}" != "YES" ]]; then
  cat >&2 <<MSG
Refusing to write without explicit confirmation.

Usage:
  CONFIRM=YES USB=/dev/sdX make flash-usb

This will overwrite the entire target device.
MSG
  exit 1
fi

if [[ -z "${USB:-}" ]]; then
  echo "USB is required, for example USB=/dev/sdX" >&2
  exit 1
fi

if [[ ! -f "${ISO}" ]]; then
  echo "ISO not found: ${ISO}" >&2
  exit 1
fi

if [[ ! -b "${USB}" ]]; then
  echo "Target is not a block device: ${USB}" >&2
  exit 1
fi

if lsblk -nr -o MOUNTPOINTS "${USB}" | grep -q '[^[:space:]]'; then
  echo "Target has mounted filesystems. Unmount them before flashing: ${USB}" >&2
  exit 1
fi

if (( EUID == 0 )); then
  SUDO=()
else
  SUDO=(sudo)
fi

echo "Writing ${ISO} to ${USB}"
"${SUDO[@]}" dd if="${ISO}" of="${USB}" bs=4M status=progress conv=fsync
"${SUDO[@]}" sync
echo "Done."
