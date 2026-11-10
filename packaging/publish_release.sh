#!/usr/bin/env bash
# NOTARIZE-6: Publish a VERIFIED Oatmeal DMG as a release asset.
#
# This script replaces (clobbers) the DMG asset — and its .sha256 sidecar —
# on the EXISTING GitHub release (default tag: v0.1.1). It NEVER creates a
# new tag or a new release, and never changes the version.
#
# Usage: bash packaging/publish_release.sh
#   RELEASE_TAG=v0.1.1   Target release tag to update (default: v0.1.1).
#                        It only ever updates that EXISTING release; if the
#                        tag does not exist the script refuses to run.
#   PUBLISH_YES=1        Skip the interactive confirmation prompt (for CI).
#                        Without it, the destructive step asks for "y".
#
# Before anything is uploaded, the DMG must pass ALL of these LOCAL checks
# (no network):
#   1. xcrun stapler validate — the notarization ticket is attached to the image.
#   2. Mount the DMG read-only so the app inside it can be inspected. The mount
#      is ALWAYS detached via a trap, even on failure.
#   3. The Oatmeal.app INSIDE the image (the artifact Gatekeeper actually
#      evaluates) is Developer ID signed, carries a valid stapled ticket, and is
#      accepted by Gatekeeper (`spctl -a -t exec`).
#      NOTE: the image FILE itself is intentionally not code-signed by this
#      pipeline, so `spctl --context context:primary-signature "$DMG"` is NOT
#      used — it always reports "no usable signature" even on a correctly
#      notarized image, and would refuse to publish a good build.
#   4. A .sha256 sidecar exists next to the DMG and its checksum matches
#      the file on disk (the sidecar is then refreshed from the file).
#
# Any failure prints exactly which check failed, exits non-zero, and
# uploads nothing.
#
# Requirements:
#   - gh CLI installed and authenticated (checked up front).
#   - The DMG built by packaging/make_dmg.sh, signed by
#     packaging/sign_app.sh, and notarized + stapled by
#     packaging/notarize_dmg.sh (prints NOTARIZE_OK: on success).
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- Inputs ------------------------------------------------------------------
# Version is read from pyproject.toml (same logic as make_dmg.sh) so the DMG
# path is derived, never hardcoded.
VERSION="0.1.1"
if [[ -f pyproject.toml ]]; then
  V="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' pyproject.toml | head -n1)"
  if [[ -n "${V:-}" ]]; then
    VERSION="$V"
  fi
fi

DMG="$REPO_ROOT/dist/Oatmeal-${VERSION}.dmg"
SHA_FILE="$DMG.sha256"
RELEASE_TAG="${RELEASE_TAG:-v0.1.1}"

# --- Pre-flight: inputs + GitHub prerequisites (before any local check) ------
[[ -f "$DMG" ]] \
  || die "DMG not found (or not a file): $DMG. Build it first with: bash packaging/make_dmg.sh (then sign and notarize it with: bash packaging/sign_app.sh && bash packaging/notarize_dmg.sh \"$DMG\")."

command -v gh >/dev/null 2>&1 \
  || die "gh CLI not found (install it from https://cli.github.com and run: gh auth login)."
gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated. Run: gh auth login (scope: repo)."

# The target release must already exist. This script only ever REPLACES
# assets on it — it must never create a tag or a release.
gh release view "$RELEASE_TAG" --json tagName \
  >/dev/null 2>&1 \
  || die "release '$RELEASE_TAG' does not exist on this remote. Refusing to run: this script only replaces assets on an EXISTING release and never creates a new one. (Set RELEASE_TAG to the right tag.)"

command -v xcrun  >/dev/null 2>&1 || die "xcrun not found (install the Xcode command line tools)."
xcrun -f stapler >/dev/null 2>&1 \
  || die "stapler not available via xcrun (install Xcode command line tools)."

echo "dmg:         $DMG"
echo "sha256:      $SHA_FILE"
echo "release tag: $RELEASE_TAG (existing release; assets will be REPLACED)"

# --- 1. Stapled? (notarization ticket attached to the image) ------------------
echo "check 1/4: xcrun stapler validate ..."
STAPLER_OUT="$(xcrun stapler validate "$DMG" 2>&1)" \
  || { printf '%s\n' "$STAPLER_OUT" >&2
       die "stapler validate FAILED for $DMG — the DMG has no valid stapled notarization ticket. Notarize it first: bash packaging/notarize_dmg.sh \"$DMG\". Refusing to publish."; }
printf '%s\n' "$STAPLER_OUT"

# --- 2. Mount the image read-only so the INNER app can be inspected -----------
# Gatekeeper evaluates the app inside the DMG, not the image file itself, so
# the meaningful Gatekeeper check (3) runs against the mounted app. The detach
# ALWAYS runs via the trap, even on failure.
echo "check 2/4: mounting $DMG read-only to inspect its app ..."
MOUNT_PT="$(mktemp -d "${TMPDIR:-/tmp}/mr-pub-mount.XXXXXX")"
MOUNTED=0
cleanup() {
  if [[ "${MOUNTED:-0}" == "1" ]]; then
    hdiutil detach "$MOUNT_PT" >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_PT"
}
trap cleanup EXIT

hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_PT" >/dev/null 2>&1 \
  || die "could not mount $DMG read-only. Refusing to publish."
MOUNTED=1

APP="$MOUNT_PT/Oatmeal.app"
[[ -d "$APP" ]] || die "Oatmeal.app not found inside $DMG (mounted at $MOUNT_PT). Refusing to publish."
echo "mounted; found Oatmeal.app."

# --- 3. The app INSIDE the image is signed, stapled, and Gatekeeper-accepted --
# NOTE: do NOT use `spctl -a -t open --context context:primary-signature "$DMG"`.
# That context demands a code signature on the .dmg FILE itself, and this
# pipeline never code-signs the image (make_dmg.sh only builds it with hdiutil;
# sign_app.sh signs the .app). It therefore always fails with
#   "<dmg>: rejected  source=no usable signature"
# on a perfectly valid, notarized DMG — which would refuse to publish a good
# build. What actually governs whether a user can run the artifact is
# Gatekeeper's verdict on the app they drag out of the image, checked here.
echo "check 3/4: inner Oatmeal.app is Developer ID signed, stapled, and accepted ..."
CODESIGN_OUT="$(codesign -dv --verbose=4 "$APP" 2>&1)" \
  || { printf '%s\n' "$CODESIGN_OUT" >&2
       die "codesign -dv failed on $APP (inside $DMG). Refusing to publish."; }
if ! grep -q "Authority=Developer ID Application" <<<"$CODESIGN_OUT"; then
  printf '%s\n' "$CODESIGN_OUT" >&2
  die "inner Oatmeal.app is NOT Developer ID signed (no 'Authority=Developer ID Application' in codesign output). Refusing to publish — sign it first with: bash packaging/sign_app.sh."
fi
echo "inner app is Developer ID signed (Authority=Developer ID Application)."

xcrun stapler validate "$APP" >/dev/null 2>&1 \
  || die "inner Oatmeal.app has no valid stapled notarization ticket — it would be rejected by Gatekeeper on a fresh Mac. Notarize it first: bash packaging/notarize_app.sh. Refusing to publish."
echo "inner app carries a valid stapled notarization ticket."

SPCTL_OUT="$(xcrun spctl -a -t exec -v "$APP" 2>&1)" \
  && SPCTL_RC=0 \
  || SPCTL_RC=$?
printf '%s\n' "$SPCTL_OUT"
if [[ "$SPCTL_RC" -ne 0 ]] || ! grep -q "accepted" <<<"$SPCTL_OUT"; then
  die "spctl (Gatekeeper) REJECTED the app inside $DMG. It must be Developer ID signed AND notarized. Refusing to publish."
fi

# --- 4. Checksum sidecar: must exist and match the file on disk ---------------
echo "check 4/4: .sha256 sidecar exists and matches the DMG on disk ..."
[[ -f "$SHA_FILE" ]] \
  || die "checksum file not found: $SHA_FILE. Refusing to publish a DMG without a verifiable checksum. (Generate one with: shasum -a 256 \"$DMG\" > \"$SHA_FILE\")"

NEW_HASH_LINE="$(shasum -a 256 "$DMG")"
NEW_HASH="${NEW_HASH_LINE%% *}"
OLD_HASH_LINE="$(sed -n '1p' "$SHA_FILE" || true)"
OLD_HASH="${OLD_HASH_LINE%% *}"
# NOTE: do NOT use ${var,,} (lowercase) here. macOS ships bash 3.2, where that
# operator is a syntax error ("bad substitution") — it aborts the script AFTER
# all the expensive checks have passed. `shasum -a 256` always prints lowercase
# hex, so a plain string comparison is both correct and portable.
if [[ -z "${OLD_HASH:-}" || "$OLD_HASH" != "$NEW_HASH" ]]; then
  die "checksum MISMATCH: $SHA_FILE records ${OLD_HASH:-<empty>} but the DMG on disk hashes to $NEW_HASH. Refusing to publish (the sidecar no longer describes this file)."
fi
# Refresh the sidecar as "<hash>  <basename>". Do NOT use the raw
# `shasum -a 256 "$DMG"` output: it prints the ABSOLUTE path, so the published
# sidecar would contain this machine's directory and be useless to anyone
# (shasum -c would fail on the path). Keep the filename only, matching the
# format the download page documents.
printf '%s  %s\n' "$NEW_HASH" "$(basename "$DMG")" > "$SHA_FILE"
echo "checksum verified: $NEW_HASH"

# --- Confirmation before the destructive step ---------------------------------
echo
echo "About to REPLACE the following assets on the EXISTING release '$RELEASE_TAG':"
echo "  - Oatmeal-${VERSION}.dmg          (replace/clobber)"
echo "  - Oatmeal-${VERSION}.dmg.sha256   (replace/clobber)"
echo "No new tag or release will be created."
if [[ "${PUBLISH_YES:-0}" != "1" ]]; then
  read -r -p "Proceed with publishing? [y/N] " CONFIRM
  case "$CONFIRM" in
    y|Y|yes|YES) ;;
    *) die "confirmation not given — nothing was published." ;;
  esac
fi

# --- Publish: replace assets on the existing release ---------------------------
echo "uploading $DMG ..."
gh release upload "$RELEASE_TAG" "$DMG" --clobber

echo "uploading $SHA_FILE ..."
gh release upload "$RELEASE_TAG" "$SHA_FILE" --clobber

# --- Summary -------------------------------------------------------------------
RELEASE_URL="$(gh release view "$RELEASE_TAG" --json url --jq .url)"
echo
echo "PUBLISH_OK: release=$RELEASE_TAG url=$RELEASE_URL"
echo "  asset: Oatmeal-${VERSION}.dmg          (replaced)"
echo "  asset: Oatmeal-${VERSION}.dmg.sha256   (replaced)"
echo "  release URL: $RELEASE_URL"
