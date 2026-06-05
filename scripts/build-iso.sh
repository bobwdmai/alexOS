#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ALEXOS_DISTRIBUTION="${ALEXOS_DISTRIBUTION:-bookworm}"
ALEXOS_ARCHITECTURE="${ALEXOS_ARCHITECTURE:-amd64}"
ALEXOS_MIRROR="${ALEXOS_MIRROR:-http://deb.debian.org/debian}"
ALEXOS_SECURITY_MIRROR="${ALEXOS_SECURITY_MIRROR:-http://security.debian.org/debian-security}"
ALEXOS_INCLUDE_CHROME="${ALEXOS_INCLUDE_CHROME:-1}"
ALEXOS_ICON_THEME="blueprint-WhiteSur-dark-GNOME"
ALEXOS_UPDATE_REPO="${ALEXOS_UPDATE_REPO:-bobwdmai/alexOS}"
ALEXOS_UPDATE_BRANCH="${ALEXOS_UPDATE_BRANCH:-main}"
ALEXOS_VERSION="${ALEXOS_VERSION:-dev}"
ALEXOS_SOURCE_COMMIT="${ALEXOS_SOURCE_COMMIT:-}"
DEBIAN_ARCHIVE_KEYRING="${DEBIAN_ARCHIVE_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"

BUILD_ROOT="${PROJECT_ROOT}/build"
BUILD_DIR="${BUILD_ROOT}/${ALEXOS_ARCHITECTURE}"
CHROOT_DIR="${BUILD_DIR}/chroot"
ISO_DIR="${BUILD_DIR}/iso"
DOWNLOAD_DIR="${BUILD_DIR}/downloads"
DIST_DIR="${PROJECT_ROOT}/dist"
PACKAGE_LIST="${PROJECT_ROOT}/config/package-lists/alexos.list.chroot"
OVERLAY_DIR="${PROJECT_ROOT}/config/includes.chroot"
ISO_PATH="${DIST_DIR}/alexOS-${ALEXOS_ARCHITECTURE}.iso"

GOOGLE_KEY_URL="https://dl.google.com/linux/linux_signing_key.pub"
GOOGLE_REPO="https://dl.google.com/linux/chrome/deb/"
WHITESUR_GTK_URL="https://github.com/vinceliuice/WhiteSur-gtk-theme/archive/refs/heads/master.tar.gz"
WHITESUR_ICON_URL="https://github.com/vinceliuice/WhiteSur-icon-theme/archive/refs/heads/master.tar.gz"

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_root() {
  if (( EUID == 0 )); then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "This build needs root privileges and sudo is not installed."
  fi

  exec sudo --preserve-env=ALEXOS_DISTRIBUTION,ALEXOS_ARCHITECTURE,ALEXOS_MIRROR,ALEXOS_SECURITY_MIRROR,ALEXOS_INCLUDE_CHROME,ALEXOS_UPDATE_REPO,ALEXOS_UPDATE_BRANCH,ALEXOS_VERSION,ALEXOS_SOURCE_COMMIT,DEBIAN_ARCHIVE_KEYRING \
    "${BASH}" "$0" "$@"
}

require_commands() {
  local missing=()
  local commands=(
    awk
    basename
    chroot
    cp
    curl
    debootstrap
    find
    gpg
    grub-mkrescue
    install
    ln
    mkdir
    mount
    mountpoint
    mksquashfs
    rm
    sed
    sha256sum
    sort
    tar
    tee
    umount
  )

  for command in "${commands[@]}"; do
    if ! command -v "${command}" >/dev/null 2>&1; then
      missing+=("${command}")
    fi
  done

  if ((${#missing[@]} > 0)); then
    printf 'Missing required host commands:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf '\nInstall host dependencies with: make deps\n' >&2
    exit 1
  fi

  if [[ ! -r "${DEBIAN_ARCHIVE_KEYRING}" ]]; then
    printf 'Missing Debian archive keyring: %s\n' "${DEBIAN_ARCHIVE_KEYRING}" >&2
    printf '\nInstall host dependencies with: make deps\n' >&2
    exit 1
  fi
}

assert_safe_paths() {
  [[ "${PROJECT_ROOT}" == /* ]] || die "Project root must be absolute."
  [[ "${BUILD_ROOT}" == "${PROJECT_ROOT}/build" ]] || die "Unexpected build root: ${BUILD_ROOT}"
  [[ "${BUILD_DIR}" == "${BUILD_ROOT}/"* ]] || die "Unexpected build directory: ${BUILD_DIR}"
  [[ "${CHROOT_DIR}" == "${BUILD_DIR}/chroot" ]] || die "Unexpected chroot directory: ${CHROOT_DIR}"
  [[ "${ISO_DIR}" == "${BUILD_DIR}/iso" ]] || die "Unexpected ISO directory: ${ISO_DIR}"
  [[ "${DIST_DIR}" == "${PROJECT_ROOT}/dist" ]] || die "Unexpected dist directory: ${DIST_DIR}"
}

is_mounted() {
  mountpoint -q "$1"
}

cleanup_mounts() {
  local mount_points=(
    "${CHROOT_DIR}/dev/pts"
    "${CHROOT_DIR}/dev"
    "${CHROOT_DIR}/proc"
    "${CHROOT_DIR}/sys"
    "${CHROOT_DIR}/run"
  )

  local mount_point
  for mount_point in "${mount_points[@]}"; do
    if [[ -d "${mount_point}" ]] && is_mounted "${mount_point}"; then
      umount -lf "${mount_point}" || true
    fi
  done
}

on_exit() {
  local status=$?
  cleanup_mounts
  if (( status != 0 )); then
    warn "Build failed. Mounts have been cleaned up; inspect ${BUILD_DIR} for leftovers."
  fi
  exit "${status}"
}

prepare_workspace() {
  log "Preparing build workspace"
  assert_safe_paths
  cleanup_mounts

  rm -rf "${CHROOT_DIR}" "${ISO_DIR}" "${DOWNLOAD_DIR}"
  mkdir -p "${CHROOT_DIR}" "${ISO_DIR}" "${DOWNLOAD_DIR}" "${DIST_DIR}"
}

bootstrap_debian() {
  log "Bootstrapping Debian ${ALEXOS_DISTRIBUTION} (${ALEXOS_ARCHITECTURE})"
  debootstrap \
    --keyring="${DEBIAN_ARCHIVE_KEYRING}" \
    --arch="${ALEXOS_ARCHITECTURE}" \
    "${ALEXOS_DISTRIBUTION}" \
    "${CHROOT_DIR}" \
    "${ALEXOS_MIRROR}"
}

write_apt_sources() {
  log "Writing Debian APT sources"
  cat > "${CHROOT_DIR}/etc/apt/sources.list" <<EOF
deb ${ALEXOS_MIRROR} ${ALEXOS_DISTRIBUTION} main contrib non-free non-free-firmware
deb ${ALEXOS_MIRROR} ${ALEXOS_DISTRIBUTION}-updates main contrib non-free non-free-firmware
deb ${ALEXOS_SECURITY_MIRROR} ${ALEXOS_DISTRIBUTION}-security main contrib non-free non-free-firmware
EOF
}

install_google_chrome_repo() {
  if [[ "${ALEXOS_INCLUDE_CHROME}" != "1" ]]; then
    warn "ALEXOS_INCLUDE_CHROME is not 1; skipping Google Chrome repo."
    return
  fi

  if [[ "${ALEXOS_ARCHITECTURE}" != "amd64" ]]; then
    warn "Google Chrome stable is only configured for amd64; skipping Chrome repo."
    return
  fi

  log "Installing Google Chrome repository key"
  install -d -m 0755 "${CHROOT_DIR}/etc/apt/keyrings"
  curl -fsSL "${GOOGLE_KEY_URL}" \
    | gpg --dearmor --yes -o "${CHROOT_DIR}/etc/apt/keyrings/google-chrome.gpg"
  chmod 0644 "${CHROOT_DIR}/etc/apt/keyrings/google-chrome.gpg"

  cat > "${CHROOT_DIR}/etc/apt/sources.list.d/google-chrome.list" <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] ${GOOGLE_REPO} stable main
EOF
}

copy_resolver() {
  if [[ -e /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"
  fi
}

mount_chroot_filesystems() {
  log "Mounting chroot filesystems"
  mkdir -p \
    "${CHROOT_DIR}/dev" \
    "${CHROOT_DIR}/dev/pts" \
    "${CHROOT_DIR}/proc" \
    "${CHROOT_DIR}/sys" \
    "${CHROOT_DIR}/run"

  mount --bind /dev "${CHROOT_DIR}/dev"
  mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"
  mount -t proc proc "${CHROOT_DIR}/proc"
  mount -t sysfs sysfs "${CHROOT_DIR}/sys"
  mount --bind /run "${CHROOT_DIR}/run"
}

chroot_run() {
  chroot "${CHROOT_DIR}" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C \
    "$@"
}

install_apt_tls_bootstrap() {
  log "Installing APT TLS bootstrap packages"
  chroot_run apt-get update
  chroot_run apt-get install -y ca-certificates curl gnupg apt-transport-https
  chroot_run update-ca-certificates
}

read_package_list() {
  [[ -f "${PACKAGE_LIST}" ]] || die "Package list missing: ${PACKAGE_LIST}"
  awk '
    {
      sub(/#.*/, "")
      for (i = 1; i <= NF; i++) {
        print $i
      }
    }
  ' "${PACKAGE_LIST}"
}

install_packages() {
  log "Installing AlexOS packages"
  local packages=()
  mapfile -t packages < <(read_package_list)

  if [[ "${ALEXOS_INCLUDE_CHROME}" == "1" && "${ALEXOS_ARCHITECTURE}" == "amd64" ]]; then
    packages+=(google-chrome-stable)
  fi

  if ((${#packages[@]} == 0)); then
    die "Package list is empty."
  fi

  printf '%s\n' "${packages[@]}" > "${BUILD_DIR}/package-manifest.txt"

  chroot_run apt-get update
  chroot_run apt-get install -y "${packages[@]}"
}

download_file() {
  local url="$1"
  local output="$2"
  curl -fL --retry 3 --retry-delay 2 "${url}" -o "${output}"
}

create_minimal_whitesur_theme() {
  log "Creating fallback WhiteSur-style theme"
  local theme_dir="${CHROOT_DIR}/usr/share/themes/WhiteSur-Dark"
  install -d \
    "${theme_dir}/gtk-3.0" \
    "${theme_dir}/gtk-4.0" \
    "${theme_dir}/gnome-shell"

  cat > "${theme_dir}/index.theme" <<'EOF'
[Desktop Entry]
Type=X-GNOME-Metatheme
Name=WhiteSur-Dark
Comment=AlexOS fallback dark glass theme

[X-GNOME-Metatheme]
GtkTheme=WhiteSur-Dark
MetacityTheme=WhiteSur-Dark
IconTheme=blueprint-WhiteSur-dark-GNOME
CursorTheme=Adwaita
ButtonLayout=close,minimize,maximize:
EOF

  cat > "${theme_dir}/gtk-3.0/gtk.css" <<'EOF'
@define-color accent_color #00b4d8;
@define-color accent_bg_color #0077b6;
@define-color accent_fg_color #ffffff;
@define-color window_bg_color #17202c;
@define-color window_fg_color #f7fbff;
@define-color headerbar_bg_color rgba(20, 31, 43, 0.94);
@define-color headerbar_fg_color #f7fbff;
@define-color card_bg_color rgba(255, 255, 255, 0.08);
@define-color popover_bg_color #1d2937;
@define-color view_bg_color #101923;
@define-color view_fg_color #f7fbff;

* {
  border-radius: 7px;
}

window,
dialog {
  background: @window_bg_color;
  color: @window_fg_color;
}

headerbar,
.titlebar {
  background: @headerbar_bg_color;
  color: @headerbar_fg_color;
  border-bottom: 1px solid rgba(255,255,255,0.12);
}

button.suggested-action {
  background: @accent_bg_color;
  color: @accent_fg_color;
}

entry,
textview,
list,
popover {
  background: @popover_bg_color;
  color: @window_fg_color;
}
EOF

  cp "${theme_dir}/gtk-3.0/gtk.css" "${theme_dir}/gtk-4.0/gtk.css"

  cat > "${theme_dir}/gnome-shell/gnome-shell.css" <<'EOF'
stage {
  color: #f7fbff;
}

#panel {
  background-color: rgba(13, 27, 42, 0.82);
  border-bottom: 1px solid rgba(0, 180, 216, 0.28);
}

.dash-background {
  background-color: rgba(13, 27, 42, 0.72);
  border: 1px solid rgba(0, 180, 216, 0.28);
  border-radius: 18px;
}
EOF
}

create_minimal_whitesur_icons() {
  log "Creating fallback WhiteSur icon theme"
  local icon_dir="${CHROOT_DIR}/usr/share/icons/WhiteSur-dark"
  install -d "${icon_dir}"

  cat > "${icon_dir}/index.theme" <<'EOF'
[Icon Theme]
Name=WhiteSur-dark
Comment=AlexOS fallback icon theme inheriting Adwaita
Inherits=Adwaita,hicolor
Directories=
EOF
}

write_blueprint_icon() {
  local output="$1"
  local label="$2"
  local accent="$3"
  local glyph="$4"

  cat > "${output}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <defs>
    <linearGradient id="plate" x1="18" y1="16" x2="110" y2="116" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#112b3c"/>
      <stop offset="1" stop-color="#07131f"/>
    </linearGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="8" stdDeviation="7" flood-color="#000814" flood-opacity="0.38"/>
    </filter>
  </defs>
  <rect x="10" y="10" width="108" height="108" rx="24" fill="url(#plate)" filter="url(#soft)"/>
  <path d="M28 24v80M48 24v80M68 24v80M88 24v80M24 40h80M24 60h80M24 80h80M24 100h80"
        fill="none" stroke="#24455a" stroke-width="1.5" opacity="0.58"/>
  <rect x="21" y="21" width="86" height="86" rx="18" fill="none" stroke="#4cc9f0" stroke-width="3"/>
  <path d="${glyph}" fill="none" stroke="${accent}" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="64" y="103" text-anchor="middle"
        font-family="Cantarell, Inter, Arial, sans-serif" font-size="18" font-weight="800"
        fill="#e8fbff">${label}</text>
</svg>
EOF
}

install_blueprint_icon_theme() {
  log "Installing ${ALEXOS_ICON_THEME} icon theme"
  local icon_root="${CHROOT_DIR}/usr/share/icons/${ALEXOS_ICON_THEME}"
  local apps_dir="${icon_root}/scalable/apps"
  local places_dir="${icon_root}/scalable/places"
  local categories_dir="${icon_root}/scalable/categories"
  local devices_dir="${icon_root}/scalable/devices"
  local status_dir="${icon_root}/scalable/status"
  local mimetypes_dir="${icon_root}/scalable/mimetypes"

  install -d \
    "${apps_dir}" \
    "${places_dir}" \
    "${categories_dir}" \
    "${devices_dir}" \
    "${status_dir}" \
    "${mimetypes_dir}"

  cat > "${icon_root}/index.theme" <<EOF
[Icon Theme]
Name=${ALEXOS_ICON_THEME}
Comment=AlexOS custom blueprint icons with GNOME fallbacks
Inherits=Adwaita,hicolor
Directories=scalable/apps,scalable/places,scalable/categories,scalable/devices,scalable/status,scalable/mimetypes

[scalable/apps]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=Applications

[scalable/places]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=Places

[scalable/categories]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=Categories

[scalable/devices]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=Devices

[scalable/status]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=Status

[scalable/mimetypes]
Size=128
MinSize=16
MaxSize=512
Type=Scalable
Context=MimeTypes
EOF

  write_blueprint_icon "${apps_dir}/alexos-setup.svg" "GO" "#7dd3fc" "M42 46h44M42 64h44M42 82h28"
  write_blueprint_icon "${apps_dir}/google-chrome.svg" "WEB" "#34d399" "M64 34a30 30 0 1 1 0 60a30 30 0 0 1 0-60M64 49a15 15 0 1 1 0 30a15 15 0 0 1 0-30M39 51h50M64 64l19 29M64 64L46 92"
  write_blueprint_icon "${apps_dir}/org.gnome.Nautilus.svg" "FILE" "#60a5fa" "M38 38h25l9 10h20v42H38zM48 60h31M48 74h31"
  write_blueprint_icon "${apps_dir}/librecad.svg" "CAD" "#22d3ee" "M39 88l22-48l29 48zM52 72h27M39 88h51"
  write_blueprint_icon "${apps_dir}/org.freecadweb.FreeCAD.svg" "3D" "#f59e0b" "M43 50l21-12l24 12v28L64 92L43 78zM64 62v30M43 50l21 12l24-12"
  cp "${apps_dir}/org.freecadweb.FreeCAD.svg" "${apps_dir}/freecad.svg"
  write_blueprint_icon "${apps_dir}/org.inkscape.Inkscape.svg" "INK" "#c084fc" "M64 34l25 29l-25 35l-25-35zM64 34v33M56 72a8 8 0 1 0 16 0a8 8 0 0 0-16 0"
  write_blueprint_icon "${apps_dir}/libreoffice-draw.svg" "DRAW" "#fb7185" "M42 86l22-44l22 44M52 72h24M42 92h44"
  write_blueprint_icon "${apps_dir}/libreoffice-writer.svg" "DOC" "#38bdf8" "M44 35h30l14 14v43H44zM74 35v15h14M54 63h24M54 76h24"
  write_blueprint_icon "${apps_dir}/libreoffice-calc.svg" "CALC" "#4ade80" "M42 38h44v52H42zM42 55h44M42 72h44M57 38v52M72 38v52"
  write_blueprint_icon "${apps_dir}/libreoffice-impress.svg" "SHOW" "#fb923c" "M42 42h44v33H42zM55 90h18M64 75v15M52 60l9-8l11 12l8-6"
  write_blueprint_icon "${apps_dir}/libreoffice-startcenter.svg" "OFF" "#2dd4bf" "M44 38h40v52H44zM52 50h24M52 64h24M52 78h18"
  write_blueprint_icon "${apps_dir}/libreoffice-math.svg" "MATH" "#a3e635" "M43 42h43M43 86h43M51 52l26 24M77 52L51 76"
  write_blueprint_icon "${apps_dir}/org.gnome.TextEditor.svg" "TXT" "#93c5fd" "M44 35h30l14 14v43H44zM74 35v15h14M54 62h22M54 76h18"
  write_blueprint_icon "${apps_dir}/org.gnome.Software.svg" "APP" "#facc15" "M42 50h44v37H42zM52 50a12 12 0 0 1 24 0M52 65h24"
  write_blueprint_icon "${apps_dir}/gimp.svg" "ART" "#fbbf24" "M45 85c18-5 24-25 38-44M80 38l10 10M42 88l17-5"
  write_blueprint_icon "${apps_dir}/blender.svg" "3D" "#fb923c" "M40 65h28M54 51l14 14l-14 14M68 65a15 15 0 1 0 30 0a15 15 0 0 0-30 0"
  write_blueprint_icon "${apps_dir}/scribus.svg" "PAGE" "#818cf8" "M45 36h28l14 14v42H45zM73 36v15h14M55 64h22M55 78h18"
  write_blueprint_icon "${apps_dir}/org.gnome.Terminal.svg" "CMD" "#67e8f9" "M38 44h52v40H38zM48 58l10 8l-10 8M63 76h17"
  write_blueprint_icon "${apps_dir}/org.gnome.Settings.svg" "SET" "#cbd5e1" "M64 42v12M64 74v12M42 64h12M74 64h12M49 49l8 8M71 71l8 8M79 49l-8 8M57 71l-8 8M56 64a8 8 0 1 0 16 0a8 8 0 0 0-16 0"
  write_blueprint_icon "${apps_dir}/org.gnome.eog.svg" "PIC" "#2dd4bf" "M40 44h48v40H40zM48 74l12-14l10 10l6-6l12 12M75 55a5 5 0 1 0 10 0a5 5 0 0 0-10 0"
  write_blueprint_icon "${apps_dir}/org.gnome.Evince.svg" "PDF" "#f87171" "M44 35h30l14 14v43H44zM74 35v15h14M54 66h24M54 78h16"
  write_blueprint_icon "${apps_dir}/org.gnome.FileRoller.svg" "ZIP" "#facc15" "M46 36h36v56H46zM58 36v56M64 42h6M58 50h6M64 58h6M58 66h6"
  write_blueprint_icon "${apps_dir}/org.gnome.tweaks.svg" "TUNE" "#a78bfa" "M42 52h44M42 76h44M56 52v-8M72 76v-8M56 52v8M72 76v8"
  write_blueprint_icon "${apps_dir}/org.gnome.Extensions.svg" "ADD" "#34d399" "M64 42v44M42 64h44M48 48l32 32M80 48L48 80"
  write_blueprint_icon "${apps_dir}/snap-store.svg" "STORE" "#facc15" "M42 50h44v37H42zM52 50a12 12 0 0 1 24 0M56 70h16"
  cp "${apps_dir}/org.gnome.Software.svg" "${apps_dir}/system-software-install.svg"
  cp "${apps_dir}/snap-store.svg" "${apps_dir}/io.snapcraft.Store.svg"

  write_blueprint_icon "${places_dir}/folder.svg" "DIR" "#60a5fa" "M36 44h25l9 10h24v36H36zM42 63h44"
  cp "${places_dir}/folder.svg" "${places_dir}/folder-documents.svg"
  cp "${places_dir}/folder.svg" "${places_dir}/folder-download.svg"
  cp "${places_dir}/folder.svg" "${places_dir}/user-home.svg"
  write_blueprint_icon "${places_dir}/user-trash.svg" "BIN" "#94a3b8" "M46 48h36M52 48v42M76 48v42M50 58h28M55 40h18"
  write_blueprint_icon "${devices_dir}/drive-harddisk.svg" "DISK" "#93c5fd" "M40 46h48v38H40zM48 72h22M78 72h2"
  write_blueprint_icon "${places_dir}/network-workgroup.svg" "NET" "#38bdf8" "M64 44v18M46 82h36M46 82l18-20l18 20M40 88h12M76 88h12M58 40h12"
  write_blueprint_icon "${categories_dir}/applications-engineering.svg" "PRO" "#22d3ee" "M40 84h48M44 76l18-38l22 38M54 62h20"
  write_blueprint_icon "${categories_dir}/applications-graphics.svg" "ART" "#f472b6" "M45 84c18-5 24-25 38-44M80 38l10 10M42 88l17-5"
  write_blueprint_icon "${categories_dir}/applications-office.svg" "DOC" "#38bdf8" "M44 35h30l14 14v43H44zM74 35v15h14M54 63h24M54 76h24"
  write_blueprint_icon "${categories_dir}/applications-internet.svg" "WEB" "#34d399" "M64 34a30 30 0 1 1 0 60a30 30 0 0 1 0-60M35 64h58M64 34c12 12 12 48 0 60M64 34c-12 12-12 48 0 60"
  write_blueprint_icon "${categories_dir}/applications-system.svg" "SYS" "#cbd5e1" "M64 42v44M42 64h44M52 52l24 24M76 52L52 76"
  write_blueprint_icon "${categories_dir}/preferences-system.svg" "SET" "#cbd5e1" "M64 42v12M64 74v12M42 64h12M74 64h12M56 64a8 8 0 1 0 16 0a8 8 0 0 0-16 0"
  write_blueprint_icon "${status_dir}/appointment-soon.svg" "TIME" "#facc15" "M44 42h40v42H44zM52 34v16M76 34v16M44 58h40M64 66v12l9 5"
  write_blueprint_icon "${mimetypes_dir}/document-new.svg" "NEW" "#e2e8f0" "M44 35h30l14 14v43H44zM74 35v15h14M54 70h24M66 58v24"

  if [[ -x "${CHROOT_DIR}/usr/bin/gtk-update-icon-cache" ]]; then
    chroot_run gtk-update-icon-cache -f -t "/usr/share/icons/${ALEXOS_ICON_THEME}" || true
  fi
}

install_whitesur_themes() {
  log "Installing WhiteSur themes"
  local gtk_tar="${DOWNLOAD_DIR}/whitesur-gtk.tar.gz"
  local icon_tar="${DOWNLOAD_DIR}/whitesur-icon.tar.gz"
  local theme_tmp="${CHROOT_DIR}/tmp/alexos-whitesur"
  local theme_ok=0
  local icon_ok=0

  if download_file "${WHITESUR_GTK_URL}" "${gtk_tar}"; then
    install -d "${theme_tmp}"
    tar -xzf "${gtk_tar}" -C "${theme_tmp}"
    if chroot_run bash -lc 'set -e; cd /tmp/alexos-whitesur/WhiteSur-gtk-theme-*; chmod +x install.sh; ./install.sh -c Dark -t all || ./install.sh -c Dark || ./install.sh'; then
      theme_ok=1
    fi
  else
    warn "WhiteSur GTK theme download failed."
  fi

  if download_file "${WHITESUR_ICON_URL}" "${icon_tar}"; then
    install -d "${theme_tmp}"
    tar -xzf "${icon_tar}" -C "${theme_tmp}"
    if chroot_run bash -lc 'set -e; cd /tmp/alexos-whitesur/WhiteSur-icon-theme-*; chmod +x install.sh; ./install.sh -d /usr/share/icons || ./install.sh'; then
      icon_ok=1
    fi
  else
    warn "WhiteSur icon theme download failed."
  fi

  if (( theme_ok == 0 )) || [[ ! -d "${CHROOT_DIR}/usr/share/themes/WhiteSur-Dark" ]]; then
    warn "Using embedded fallback GTK/Shell theme."
    create_minimal_whitesur_theme
  fi

  if (( icon_ok == 0 )) || [[ ! -d "${CHROOT_DIR}/usr/share/icons/WhiteSur-dark" ]]; then
    warn "Using embedded fallback icon theme."
    create_minimal_whitesur_icons
  fi
}

apply_overlay() {
  log "Applying chroot overlay"
  [[ -d "${OVERLAY_DIR}" ]] || die "Overlay directory missing: ${OVERLAY_DIR}"
  cp -a "${OVERLAY_DIR}/." "${CHROOT_DIR}/"
}

detect_source_commit() {
  if [[ -n "${ALEXOS_SOURCE_COMMIT}" ]]; then
    printf '%s\n' "${ALEXOS_SOURCE_COMMIT}"
    return
  fi

  if command -v git >/dev/null 2>&1 && git -C "${PROJECT_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${PROJECT_ROOT}" rev-parse HEAD
    return
  fi

  printf 'dev\n'
}

configure_alexos_metadata() {
  log "Writing AlexOS update metadata"
  local source_commit
  source_commit="$(detect_source_commit)"

  install -d "${CHROOT_DIR}/etc/alexos"
  printf '%s\n' "${ALEXOS_VERSION}" > "${CHROOT_DIR}/etc/alexos/version"
  printf '%s\n' "${source_commit}" > "${CHROOT_DIR}/etc/alexos/source-commit"

  cat > "${CHROOT_DIR}/etc/alexos/update.conf" <<EOF
ALEXOS_UPDATE_REPO="${ALEXOS_UPDATE_REPO}"
ALEXOS_UPDATE_BRANCH="${ALEXOS_UPDATE_BRANCH}"
ALEXOS_UPDATE_AUTO_APPLY="1"
ALEXOS_ICON_THEME="${ALEXOS_ICON_THEME}"
EOF
}

configure_locale_timezone() {
  log "Configuring locale and timezone"
  echo "en_US.UTF-8 UTF-8" > "${CHROOT_DIR}/etc/locale.gen"
  echo "LANG=en_US.UTF-8" > "${CHROOT_DIR}/etc/default/locale"
  chroot_run locale-gen

  ln -snf /usr/share/zoneinfo/America/New_York "${CHROOT_DIR}/etc/localtime"
  echo "America/New_York" > "${CHROOT_DIR}/etc/timezone"
  chroot_run dpkg-reconfigure -f noninteractive tzdata
}

configure_dconf() {
  log "Configuring GNOME defaults"
  install -d "${CHROOT_DIR}/etc/dconf/profile" "${CHROOT_DIR}/etc/dconf/db/alexos.d"

  cat > "${CHROOT_DIR}/etc/dconf/profile/user" <<'EOF'
user-db:user
system-db:alexos
EOF

  cat > "${CHROOT_DIR}/etc/dconf/db/alexos.d/01-appearance" <<'EOF'
[org/gnome/desktop/interface]
gtk-theme='WhiteSur-Dark'
icon-theme='blueprint-WhiteSur-dark-GNOME'
color-scheme='prefer-dark'
clock-format='12h'
font-name='Cantarell 11'
document-font-name='Cantarell 11'
monospace-font-name='Monospace 11'

[org/gnome/desktop/wm/preferences]
button-layout='close,minimize,maximize:'
theme='WhiteSur-Dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/alexos-wallpaper.svg'
picture-uri-dark='file:///usr/share/backgrounds/alexos-wallpaper.svg'
picture-options='zoom'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/alexos-wallpaper.svg'
primary-color='#0d1b2a'
secondary-color='#00b4d8'

[org/gnome/shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com','user-theme@gnome-shell-extensions.gcampax.github.com']
favorite-apps=['google-chrome.desktop','org.gnome.Nautilus.desktop','librecad.desktop','freecad.desktop','org.inkscape.Inkscape.desktop','libreoffice-draw.desktop','org.gnome.TextEditor.desktop','org.gnome.Software.desktop']

[org/gnome/shell/extensions/user-theme]
name='WhiteSur-Dark'

[org/gnome/shell/extensions/dash-to-dock]
dock-position='BOTTOM'
autohide=true
intellihide=true
dock-fixed=false
extend-height=false
dash-max-icon-size=48
show-trash=false
show-mounts=true
EOF

  chroot_run dconf update
}

configure_permissions() {
  log "Setting overlay permissions"
  local executable_paths=(
    /usr/local/bin/alexos-setup-wizard
    /usr/local/bin/alexos-welcome
    /usr/local/sbin/alexos-update
    /usr/local/sbin/alexos-install-snap-store
  )

  local path
  for path in "${executable_paths[@]}"; do
    if [[ -f "${CHROOT_DIR}${path}" ]]; then
      chmod 0755 "${CHROOT_DIR}${path}"
    fi
  done

  if [[ -f "${CHROOT_DIR}/etc/sudoers.d/alexos-live" ]]; then
    chmod 0440 "${CHROOT_DIR}/etc/sudoers.d/alexos-live"
    chroot_run visudo -cf /etc/sudoers
  fi

  find "${CHROOT_DIR}/usr/share/applications" -maxdepth 1 -name 'alexos-*.desktop' -exec chmod 0644 {} +
  if [[ -d "${CHROOT_DIR}/etc/xdg/autostart" ]]; then
    find "${CHROOT_DIR}/etc/xdg/autostart" -maxdepth 1 -name 'alexos-*.desktop' -exec chmod 0644 {} +
  fi
}

enable_service() {
  local service="$1"
  chroot_run systemctl enable "${service}"
}

enable_services() {
  log "Enabling system services"
  enable_service NetworkManager.service

  if ! enable_service gdm3.service; then
    enable_service gdm.service
  fi

  enable_service snapd.socket
  enable_service alexos-first-boot.service
  enable_service alexos-snap-store.service
  enable_service alexos-update.timer
}

prepare_boot_artifacts() {
  log "Updating initramfs"
  chroot_run update-initramfs -u -k all
}

clean_chroot() {
  log "Cleaning chroot"
  chroot_run apt-get clean

  find "${CHROOT_DIR}/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  find "${CHROOT_DIR}/var/tmp" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  rm -rf "${CHROOT_DIR}/var/lib/apt/lists"
  install -d -m 0755 "${CHROOT_DIR}/var/lib/apt/lists/partial"

  find "${CHROOT_DIR}/var/log" -type f -exec truncate -s 0 {} +

  : > "${CHROOT_DIR}/etc/machine-id"
  rm -f "${CHROOT_DIR}/var/lib/dbus/machine-id"
  ln -s /etc/machine-id "${CHROOT_DIR}/var/lib/dbus/machine-id"
}

write_iso_metadata() {
  log "Writing ISO metadata"
  install -d "${ISO_DIR}/.disk" "${ISO_DIR}/boot/grub" "${ISO_DIR}/live"
  echo "AlexOS ${ALEXOS_DISTRIBUTION} ${ALEXOS_ARCHITECTURE}" > "${ISO_DIR}/.disk/info"
  printf 'AlexOS Live ISO\nDistribution: %s\nArchitecture: %s\n' \
    "${ALEXOS_DISTRIBUTION}" \
    "${ALEXOS_ARCHITECTURE}" \
    > "${ISO_DIR}/README.txt"
}

copy_kernel_and_initrd() {
  log "Copying kernel and initrd"
  local kernel
  local initrd

  kernel="$(find "${CHROOT_DIR}/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort -V | tail -n 1)"
  initrd="$(find "${CHROOT_DIR}/boot" -maxdepth 1 -type f -name 'initrd.img-*' | sort -V | tail -n 1)"

  [[ -n "${kernel}" ]] || die "No kernel found in chroot /boot."
  [[ -n "${initrd}" ]] || die "No initrd found in chroot /boot."

  cp "${kernel}" "${ISO_DIR}/live/vmlinuz"
  cp "${initrd}" "${ISO_DIR}/live/initrd.img"
}

build_squashfs() {
  log "Building SquashFS"
  mkdir -p "${ISO_DIR}/live"
  du -sx --block-size=1 "${CHROOT_DIR}" | awk '{print $1}' > "${ISO_DIR}/live/filesystem.size"
  mksquashfs "${CHROOT_DIR}" "${ISO_DIR}/live/filesystem.squashfs" \
    -comp xz \
    -b 1M \
    -noappend \
    -e boot
}

write_grub_config() {
  log "Writing GRUB configuration"
  install -d "${ISO_DIR}/boot/grub"
  cat > "${ISO_DIR}/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5

insmod all_video
insmod gfxterm
insmod png

if loadfont /boot/grub/font.pf2 ; then
  set gfxmode=auto
  terminal_output gfxterm
fi

menuentry "AlexOS Live" {
  linux /live/vmlinuz boot=live components live-config.username=alex live-config.hostname=alexos quiet splash
  initrd /live/initrd.img
}

menuentry "AlexOS Live (failsafe graphics)" {
  linux /live/vmlinuz boot=live components live-config.username=alex live-config.hostname=alexos nomodeset noapic noacpi
  initrd /live/initrd.img
}
EOF
}

build_rescue_iso() {
  log "Building bootable ISO"
  rm -f "${ISO_PATH}" "${ISO_PATH}.sha256"
  grub-mkrescue \
    -o "${ISO_PATH}" \
    -volid "ALEXOS_${ALEXOS_ARCHITECTURE}" \
    "${ISO_DIR}"
}

write_checksum() {
  log "Writing SHA256 checksum"
  (
    cd "${DIST_DIR}"
    sha256sum "$(basename "${ISO_PATH}")" > "$(basename "${ISO_PATH}").sha256"
  )
}

print_summary() {
  log "AlexOS ISO complete"
  printf 'ISO:     %s\n' "${ISO_PATH}"
  printf 'SHA256:  %s.sha256\n' "${ISO_PATH}"
  printf '\nVerify with:\n'
  printf '  sha256sum -c %q\n' "${ISO_PATH}.sha256"
  printf '\nRun in QEMU with:\n'
  printf '  make run-qemu\n'
}

main() {
  need_root "$@"
  trap on_exit EXIT

  require_commands
  prepare_workspace
  bootstrap_debian
  write_apt_sources
  copy_resolver
  mount_chroot_filesystems
  install_apt_tls_bootstrap
  install_google_chrome_repo
  install_packages
  install_whitesur_themes
  install_blueprint_icon_theme
  apply_overlay
  configure_alexos_metadata
  configure_locale_timezone
  configure_dconf
  configure_permissions
  enable_services
  prepare_boot_artifacts
  clean_chroot
  cleanup_mounts
  write_iso_metadata
  copy_kernel_and_initrd
  build_squashfs
  write_grub_config
  build_rescue_iso
  write_checksum
  print_summary
}

main "$@"
