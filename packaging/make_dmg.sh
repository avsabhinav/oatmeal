#!/usr/bin/env bash
# PKG-B1: Build all deliverables fresh and assemble a distributable DMG.
#
# Usage: ./packaging/make_dmg.sh   (from anywhere; idempotent, user-local only)
#        MR_SIGN=1 ./packaging/make_dmg.sh
#          Opt-in: Developer ID signing + notarization (sign_app.sh +
#          notarize_app.sh + notarize_dmg.sh). Unset (the default):
#          adhoc-signed build as before.
#
# What it does:
#   1. Builds the mr-capture helper from source (capture/build.sh) and freezes
#      the mr CLI (packaging/freeze_cli.sh), so both bundled binaries are
#      always current — a stale artifact must never ship. menu-bar/install.sh
#      only COPIES mr-capture from capture/.build/release, so without this
#      step the DMG silently carries whatever helper was last built by hand
#      (this shipped an 11-day-old mr-capture through several reinstalls).
#   2. Builds Oatmeal.app (with the embedded frozen CLI + mr-capture inside)
#      via menu-bar/install.sh
#      With MR_SIGN=1: signs it (sign_app.sh), then NOTARIZES + STAPLES THE
#      .APP ITSELF (notarize_app.sh) BEFORE the DMG is built — so the bundle
#      carries its own ticket and passes Gatekeeper once dragged out of the
#      DMG. Stapling only the DMG is NOT sufficient: the ticket does not
#      survive the app being copied to /Applications.
#   3. Stages a DMG volume containing ONLY:
#        Oatmeal.app
#        Applications -> /Applications   (drag-to-install affordance)
#      (single-drag; PKG-BUNDLE/5)
#   4. Creates dist/Oatmeal-<VERSION>.dmg with hdiutil (UDZO, -ov), with a
#      size computed from the staged content, and opens a laid-out Finder
#      drag window.
#
# By default the app is adhoc-signed (no Developer ID) — the local
# distribution path, unchanged. With MR_SIGN=1, the assembled app is
# re-signed with a Developer ID Application certificate (hardened runtime)
# via packaging/sign_app.sh, then notarized and stapled AS AN .app
# (packaging/notarize_app.sh) so the bundle carries its own ticket; the
# DMG is then built from the already-stapled app and itself submitted to
# Apple, stapled, and verified (packaging/notarize_dmg.sh) — one command,
# fully notarized output in which the installed app passes Gatekeeper on
# its own.
# PKG_DMG_STAGE_ONLY=1: assemble staging + layout, exit before hdiutil
# (for sandboxed CI where hdiutil device/mount ops are denied). With
# MR_SIGN=1 the app is still signed AND notarized+stapled in this mode
# (stapling is a build-time property of the bundle and the caller asked
# for MR_SIGN=1) — NOTE: that app notarization is a network submission and
# can take several minutes, making stage-only builds slow. The DMG
# notarization obviously does not run because no DMG is written.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# --- MR_SIGN: opt-in Developer ID signing + notarization. -------------------
# Unset/0 (the default): adhoc-signed local build, exactly as before.
# 1: after menu-bar/install.sh, re-sign the assembled app with a Developer ID
#    certificate (packaging/sign_app.sh), then notarize + staple the .app
#    ITSELF (packaging/notarize_app.sh) so the bundle carries its own ticket;
#    after the DMG is written, submit IT too, staple, and verify
#    (packaging/notarize_dmg.sh).
MR_SIGN="${MR_SIGN:-0}"
if [[ "$MR_SIGN" == "1" ]]; then
  # Convenience: if DEVELOPER_ID_APP is not already in the environment, pick
  # up packaging/signing.env (never committed; see signing.env.example).
  # Absent file is fine — sign_app.sh validates and fails loudly if the
  # identity is still missing.
  if [[ -z "${DEVELOPER_ID_APP:-}" && -f "$REPO_ROOT/packaging/signing.env" ]]; then
    echo "==> MR_SIGN=1: sourcing packaging/signing.env (DEVELOPER_ID_APP was unset)"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/packaging/signing.env"
  fi
fi

# --- Version: read from pyproject.toml, fall back to a constant. -----------
VERSION="0.1.1"
if [[ -f pyproject.toml ]]; then
  V="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' pyproject.toml | head -n1)"
  if [[ -n "${V:-}" ]]; then
    VERSION="$V"
  fi
fi

OUTPUT_DIR="$REPO_ROOT/dist"
OUTPUT_DMG="$OUTPUT_DIR/Oatmeal-${VERSION}.dmg"
mkdir -p "$OUTPUT_DIR"

# --- Staging dir + cleanup (removes staging, mount point, raw image on exit). -
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/mr-dmg.XXXXXX")"
raw_image=""
MOUNT_PT=""
cleanup() {
  [[ -n "$MOUNT_PT" ]] && hdiutil detach "$MOUNT_PT" >/dev/null 2>&1 || true
  rm -rf "$STAGING" "$MOUNT_PT" "$raw_image"
}
trap cleanup EXIT

VOL="$STAGING/volume"
mkdir -p "$VOL"

# --- 1. Build all artifacts fresh from source. ------------------------------
# Build the Swift capture helper FIRST. menu-bar/install.sh only *copies*
# capture/.build/release/mr-capture into the bundle — it never builds it — so
# without this the DMG ships whatever helper happens to be lying in the build
# dir. Same rule as the CLI freeze below: nothing stale leaves this script.
echo "==> Building the mr-capture helper from source (capture/build.sh)"
bash capture/build.sh

# Freeze the CLI from the current source. `install.sh` embeds whatever is
# in dist-freeze/mr-cli, so re-freezing here guarantees the DMG cannot carry a
# stale binary (the working tree's cli.py is the source of truth).
echo "==> Freezing the mr CLI from source (packaging/freeze_cli.sh)"
bash packaging/freeze_cli.sh

echo "==> Building Oatmeal.app (menu-bar/install.sh; embeds the frozen CLI + mr-capture)"
bash menu-bar/install.sh

APP_SRC="$REPO_ROOT/menu-bar/.build/Release/Oatmeal.app"

if [[ ! -d "$APP_SRC" ]]; then
  echo "make_dmg.sh: missing $APP_SRC (did menu-bar/install.sh succeed?)" >&2
  exit 1
fi

# MR_SIGN=1: re-sign the assembled app with the Developer ID certificate
# (hardened runtime, inside-out). sign_app.sh signs with --force, replacing
# the adhoc signature menu-bar/install.sh applied. A failure aborts the whole
# build under `set -e` — never ship a half-signed app.
# Then (NOTARIZE-7b): notarize + staple the .app ITSELF, BEFORE the DMG is
# built, so the bundle carries its own stapled ticket (inside
# Oatmeal.app/_CodeSignature) and passes Gatekeeper after being dragged out
# of the DMG to /Applications. Stapling only the DMG (the old flow) loses the
# ticket on copy — reproduced defect: spctl rejects the installed app with
# "the code is valid but does not seem to be an app". A failure here must
# also abort the build — never ship an un-notarized app.
if [[ "$MR_SIGN" == "1" ]]; then
  echo "==> Signing Oatmeal.app with Developer ID (packaging/sign_app.sh)"
  bash packaging/sign_app.sh "$APP_SRC"

  echo "==> Notarizing + stapling Oatmeal.app (packaging/notarize_app.sh)"
  bash packaging/notarize_app.sh "$APP_SRC"
fi

# --- 2. Assemble the volume staging directory. ------------------------------
# The volume now contains ONLY Oatmeal.app (with the embedded frozen CLI +
# mr-capture inside it) and the Applications symlink — single-drag; PKG-BUNDLE/5.
cp -R "$APP_SRC" "$VOL/Oatmeal.app"

# Drag-to-install affordance.
ln -s /Applications "$VOL/Applications"

# Compute a raw-image size that surely fits the staged content. The app is
# ~950 MB (embedded frozen CLI across ~3k small files), so a fixed 200m can
# never hold it. du -sk gives KiB; convert to MiB, then add a generous margin:
# HFS+ allocates in large blocks and adds per-file metadata, so the raw volume
# needs *notably* more than the apparent size (100m cushion proved too small on
# a real build). Use 50% headroom with a 1536m floor (plain 1.5 GiB works fine;
# the UDZO-compressed output is far smaller than the raw image).
APP_MB=$(($(du -sk "$VOL" | awk '{print $1}') / 1024))
SIZE_MB=$((APP_MB + APP_MB / 2))
if [[ $SIZE_MB -lt 1536 ]]; then SIZE_MB=1536; fi

# PKG_DMG_STAGE_ONLY=1: assemble staging + layout, then exit before hdiutil
# (for sandboxed CI where hdiutil device/mount ops are denied). No DMG written.
if [[ "${PKG_DMG_STAGE_ONLY:-0}" == "1" ]]; then
  echo "==> STAGE_ONLY: staging complete at $VOL (cleanup removes it on exit)"
  echo "==> STAGE_ONLY SIZE_MB=${SIZE_MB}m"
  echo "==> STAGE_ONLY content:"; find "$VOL" -maxdepth 1 -print | sort
  exit 0
fi

# --- 3. Create the DMG (compressed, overwrite any existing one). ------------
# `hdiutil create -srcfolder` fails with "Directory not empty" on recent macOS,
# so build a blank image, mount it, copy the staging tree in, then detach and
# convert to compressed UDZO.
echo "==> Creating $OUTPUT_DMG"
rm -f "$OUTPUT_DMG"
raw_image="$(mktemp -u "${TMPDIR:-/tmp}/mr-raw.XXXXXX").dmg"
MOUNT_PT="$(mktemp -d "${TMPDIR:-/tmp}/mr-mount.XXXXXX")"

hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "Oatmeal" "$raw_image" >/dev/null
hdiutil attach "$raw_image" -mountpoint "$MOUNT_PT" -nobrowse >/dev/null
# Copy the staging tree (including the Applications symlink) into the volume.
ditto "$VOL" "$MOUNT_PT"

# Open + lay out the mounted window so double-clicking the DMG shows the
# classic "drag Oatmeal.app to Applications" window immediately.
open "$MOUNT_PT"
osascript -e 'tell application "Finder" to activate' \
  -e 'tell application "Finder" to set the bounds of the front window to {50, 50, 520, 480}' \
    >/dev/null 2>&1 || true

hdiutil detach "$MOUNT_PT" >/dev/null
hdiutil convert "$raw_image" -format UDZO -o "$OUTPUT_DMG"

# MR_SIGN=1: the DMG was built from the ALREADY-notarized-and-stapled app
# (notarize_app.sh ran before hdiutil). Now also submit the DMG itself to
# Apple's notary service, wait for the verdict, staple its ticket, and verify
# Gatekeeper. A failure must abort with a clear message — never ship an
# unnotarized "signed" DMG.
if [[ "$MR_SIGN" == "1" ]]; then
  echo "==> Notarizing $OUTPUT_DMG (packaging/notarize_dmg.sh)"
  if ! bash packaging/notarize_dmg.sh "$OUTPUT_DMG"; then
    echo "make_dmg.sh: ERROR — notarization FAILED. The DMG at $OUTPUT_DMG is" >&2
    echo "make_dmg.sh: signed but NOT notarized/stapled. Do not distribute it." >&2
    exit 1
  fi
fi

# --- 4. Done. ---------------------------------------------------------------
echo
echo "==> DMG ready: $OUTPUT_DMG"
if [[ "$MR_SIGN" == "1" ]]; then
  echo "==> Mode: Developer ID signed; .app notarized + stapled BEFORE the DMG; DMG also notarized + stapled (MR_SIGN=1)"
  echo "==> An Oatmeal.app copied out of this DMG passes Gatekeeper on its own (ticket is stapled inside the bundle)"
else
  echo "==> Mode: adhoc-signed, not notarized (MR_SIGN unset/0)"
fi
echo "==> Verify with: hdiutil verify \"$OUTPUT_DMG\""
