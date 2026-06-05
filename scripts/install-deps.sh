#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
  SUDO=()
else
  SUDO=(sudo)
fi

packages=(
  debootstrap
  debian-archive-keyring
  squashfs-tools
  grub-pc-bin
  grub-efi-amd64-bin
  xorriso
  mtools
  python3
  python3-gi
  gir1.2-gtk-4.0
  gir1.2-adw-1
  curl
  gnupg
  ca-certificates
)

"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install -y "${packages[@]}"

cat <<'MSG'
AlexOS host dependencies are installed.

Optional for VM testing:
  sudo apt-get install -y qemu-system-x86
MSG
