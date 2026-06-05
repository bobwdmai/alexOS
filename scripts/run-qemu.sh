#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${ALEXOS_ARCHITECTURE:-amd64}"
ISO="${ISO:-${ROOT_DIR}/dist/alexOS-${ARCH}.iso}"
MEMORY="${ALEXOS_QEMU_MEMORY:-4096}"
CPUS="${ALEXOS_QEMU_CPUS:-2}"
DISPLAY_BACKEND="${ALEXOS_QEMU_DISPLAY:-gtk,gl=on}"

if [[ ! -f "${ISO}" ]]; then
  echo "ISO not found: ${ISO}" >&2
  echo "Build it first with: make iso" >&2
  exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "qemu-system-x86_64 is not installed." >&2
  echo "Install it with: sudo apt-get install -y qemu-system-x86" >&2
  exit 1
fi

kvm_args=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  kvm_args=(-enable-kvm)
fi

exec qemu-system-x86_64 \
  -cdrom "${ISO}" \
  -m "${MEMORY}" \
  -smp "${CPUS}" \
  -vga virtio \
  -display "${DISPLAY_BACKEND}" \
  "${kvm_args[@]}" \
  -boot d \
  "$@"
