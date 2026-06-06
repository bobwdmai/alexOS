# AlexOS

AlexOS is a Debian-based live ISO with a simple first-boot setup flow, GNOME desktop defaults, pro creative/CAD tools, an AlexOS Software & Updates app, and a custom `blueprint-WhiteSur-dark-GNOME` icon theme.

## Build

```bash
make deps
make iso
make run-qemu
```

If the Google Chrome repository is blocked on your network:

```bash
ALEXOS_INCLUDE_CHROME=0 make iso
```

## Install On A PC

Boot the ISO from a USB drive, then open **Install AlexOS** from the dock or desktop. The installer can replace Windows by erasing the selected disk, so back up important files first and choose the disk option carefully.

The ISO includes Calamares, bootloader tools for BIOS/UEFI systems, NTFS/exFAT support for Windows drives and USB disks, common firmware packages, Firefox, and LibreOffice basics.

## Fast Updates

Built AlexOS systems include `alexos-update`, a small updater that checks this GitHub repo for the latest `main` commit. It downloads the source tarball and applies only `config/includes.chroot` onto the system, so GUI, icon, service, and script updates are much faster than downloading a whole ISO.

Manual check:

```bash
alexos-update check
```

Manual apply:

```bash
sudo alexos-update apply
```

Automatic checks run through `alexos-update.timer` every 10 minutes after boot.

Package, kernel, and deep base-system changes still need a new ISO.

## Release

Create or update a GitHub release from a local ISO:

```bash
VERSION=v0.1.0 make release
```

Tags that start with `v` also trigger the GitHub Actions ISO build workflow.
