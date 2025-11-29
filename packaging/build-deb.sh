#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# packaging/build-deb.sh
# Usage: packaging/build-deb.sh <staging-dir> <install-prefix> <out-dir> <version>
# Example:
#   packaging/build-deb.sh "$GITHUB_WORKSPACE/staging" /usr "$GITHUB_WORKSPACE/out" "20251129-abcdef0"

STAGING_DIR="${1:-${GITHUB_WORKSPACE:-.}/staging}"
PREFIX="${2:-/usr}"
OUT_DIR="${3:-${GITHUB_WORKSPACE:-.}/out}"
VERSION="${4:-unknown}"
PKG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kodi-deb.XXXXXX")"

cleanup() {
  rc=$?
  # keep package dir if failure for debug
  if [ $rc -ne 0 ]; then
    echo "ERROR: packaging failed (exit $rc). Packaging tree preserved at: ${PKG_DIR}" >&2
  else
    rm -rf "${PKG_DIR}"
  fi
  exit $rc
}
trap cleanup INT TERM EXIT

echo "Packaging:"
echo "  STAGING_DIR=${STAGING_DIR}"
echo "  PREFIX=${PREFIX}"
echo "  OUT_DIR=${OUT_DIR}"
echo "  VERSION=${VERSION}"
echo "  TEMP PKG_DIR=${PKG_DIR}"

# create package root
mkdir -p "${PKG_DIR}${PREFIX}"

# copy staging tree to package dir
# rsync handles symlinks, permissions and avoids copying file onto itself more cleanly than cp -a
rsync -a --delete --links --perms --chmod=ugo=rX "${STAGING_DIR}${PREFIX}/" "${PKG_DIR}${PREFIX}/"

# desktop entry + icons
DESKTOP_DIR="${PKG_DIR}/usr/share/applications"
ICON_DIR="${PKG_DIR}/usr/share/icons/hicolor/256x256/apps"
mkdir -p "${DESKTOP_DIR}" "${ICON_DIR}"

cat > "${DESKTOP_DIR}/kodi.desktop" <<'DESKTOP_EOF'
[Desktop Entry]
Name=Kodi
GenericName=Media Center
Comment=Play media and manage library
Exec=/usr/bin/kodi %U
Terminal=false
Type=Application
Categories=AudioVideo;Player;Video;
MimeType=video/*;audio/*;
Icon=kodi
StartupNotify=true
DESKTOP_EOF

# safe copy: use source inside staging if exists; skip if identical
SRC_ICON="${PKG_DIR}${PREFIX}/share/icons/hicolor/256x256/apps/kodi.png"
DST_ICON="${ICON_DIR}/kodi.png"
if [ -f "${SRC_ICON}" ]; then
  if [ ! -e "${DST_ICON}" ] || ! cmp -s "${SRC_ICON}" "${DST_ICON}"; then
    install -D -m 0644 "${SRC_ICON}" "${DST_ICON}"
  else
    echo "Icon identical -> skip"
  fi
fi

# prepare DEBIAN dir
DEBIAN_DIR="${PKG_DIR}/DEBIAN"
mkdir -p "${DEBIAN_DIR}"

# control file: prefer packaging/control.template if present
REPO_PACKAGING_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${REPO_PACKAGING_DIR}/control.template"
if [ -f "${TEMPLATE}" ]; then
  sed -e "s|%VERSION%|${VERSION}|g" -e "s|%ARCH%|amd64|g" "${TEMPLATE}" > "${DEBIAN_DIR}/control"
else
  cat > "${DEBIAN_DIR}/control" <<'CONTROL_EOF'
Package: kodi
Version: PLACEHOLDER_VERSION
Section: video
Priority: optional
Architecture: amd64
Maintainer: Kodi Packager <noreply@example.com>
Description: Kodi Media Center (custom build)
CONTROL_EOF
  sed -i "s|PLACEHOLDER_VERSION|${VERSION}|g" "${DEBIAN_DIR}/control"
fi

# optional postinst/prerm packaging scripts (from repo packaging/)
if [ -f "${REPO_PACKAGING_DIR}/postinst" ]; then
  install -m 0755 "${REPO_PACKAGING_DIR}/postinst" "${DEBIAN_DIR}/postinst"
else
  cat > "${DEBIAN_DIR}/postinst" <<'POSTINST_EOF'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor || true
fi
exit 0
POSTINST_EOF
  chmod 0755 "${DEBIAN_DIR}/postinst"
fi

if [ -f "${REPO_PACKAGING_DIR}/prerm" ]; then
  install -m 0755 "${REPO_PACKAGING_DIR}/prerm" "${DEBIAN_DIR}/prerm"
fi

# set safe perms
chmod -R 0755 "${DEBIAN_DIR}"
# Ensure files owned by root in package (dpkg-deb doesn't require root but ownership isn't relevant inside the .deb)
# Build .deb with fakeroot for correct metadata
mkdir -p "${OUT_DIR}"

PKG_NAME="kodi-elementary-${VERSION}_amd64.deb"
echo "Building ${OUT_DIR}/${PKG_NAME} ..."
fakeroot dpkg-deb --build "${PKG_DIR}" "${OUT_DIR}/${PKG_NAME}"

# optional: compute shared library dependencies using dpkg-shlibdeps
# Instead of extracting the .deb (which can create root-owned files), run dpkg-shlibdeps
# directly against the packaged tree (PKG_DIR). This avoids creating /tmp/deb-unpack.* and
# avoids permission errors.
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
  echo "Running dpkg-shlibdeps to compute shared library dependencies (optional)"
  BIN_PATH="${PKG_DIR}${PREFIX}/usr/bin/kodi"
  if [ -x "${BIN_PATH}" ]; then
    # dpkg-shlibdeps expects a path to one or more binaries; -O prints the dependency string
    # Append the resolved shlibs to control file (non-fatal)
    echo " -> computing shlibs for: ${BIN_PATH}"
    dpkg-shlibdeps -O "${BIN_PATH}" >> "${DEBIAN_DIR}/control" 2>/dev/null || {
      echo "dpkg-shlibdeps failed (non-fatal), continuing..."
    }
  else
    echo "Binary not found or not executable at ${BIN_PATH}; skipping dpkg-shlibdeps"
  fi
else
  echo "dpkg-shlibdeps not found; skipping optional shared-lib dependency scan"
fi

echo "Package created: ${OUT_DIR}/${PKG_NAME}"
# cleanup handled by trap
exit 0
