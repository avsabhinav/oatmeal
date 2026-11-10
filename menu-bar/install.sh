#!/usr/bin/env bash
# Build Oatmeal and assemble the menu-bar .app bundle (MB-SW4).
#
# Usage: ./install.sh   (from anywhere; idempotent, no sudo)
#
# Produces:
#   menu-bar/.build/Release/Oatmeal.app
#     Contents/MacOS/Oatmeal   (the release binary from ./build.sh)
#     Contents/Info.plist      (LSUIElement + mic/audio usage strings)
#
# The bundle is left in the build dir — drag it into /Applications manually
# (see docs). It is adhoc-signed like the rest of the repo.
set -euo pipefail
cd "$(dirname "$0")"

# Overwrite the menu-bar glyph with the new branding asset so SwiftPM bundles
# the NEW icon into Oatmeal_Oatmeal.bundle (BRAND-2).
cp -f "../assets/branding/icon-white.png" "Sources/Oatmeal/Resources/icon-white.png"
cp -f "../assets/branding/appIcon-recording.png" "Sources/Oatmeal/Resources/icon-recording.png"

./build.sh

BIN="$(pwd)/.build/release/Oatmeal"
APP="$(pwd)/.build/Release/Oatmeal.app"
FROZEN_CLI="$(pwd)/../dist-freeze/mr-cli"     # repo-root frozen onedir tree
CAP_BIN="$(pwd)/../capture/.build/release/mr-capture"
RES_DIR="$APP/Contents/Resources"

if [[ ! -x "$BIN" ]]; then
  echo "install.sh: expected executable not found at $BIN" >&2
  exit 1
fi

# Assemble a minimal .app bundle (idempotent: overwrite on re-run).
mkdir -p "$APP/Contents/MacOS"
cp -f "$BIN" "$APP/Contents/MacOS/Oatmeal"
chmod +x "$APP/Contents/MacOS/Oatmeal"
cp -f "$(pwd)/Info.plist" "$APP/Contents/Info.plist"

# PkgInfo: the classic 8-byte type/creator file every real .app bundle has
# (e.g. Calculator.app -> "APPL????"). Without it — together with the
# CFBundlePackageType=APPL key in Info.plist — Gatekeeper does not recognize the
# bundle as an application and rejects it even when the signature is valid and
# notarization was accepted, with the literal message:
#   "rejected (the code is valid but does not seem to be an app)"
# Adding it costs nothing and makes the bundle structurally standard.
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Bundle the new app icon (BRAND-2): Finder reads it via CFBundleIconFile.
mkdir -p "$RES_DIR"
cp -f "$(pwd)/../assets/branding/app.icns" "$RES_DIR/app.icns"

# Copy the SwiftPM resource bundle into Contents/Resources/. SwiftPM emits the
# bundled PNGs (menu-bar icon, logo) as a separate `Oatmeal_Oatmeal.bundle` that is
# NOT inside the .app by default; Bundle.module resolves it via
# Bundle.main.resourceURL, so without this copy the app Fatal-errors at launch
# ("unable to find bundle named Oatmeal_Oatmeal") and shows no icon. Guarded because
# a resource-less build may not emit it.
RES_BUNDLE="$(pwd)/.build/release/Oatmeal_Oatmeal.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  mkdir -p "$RES_DIR"
  rm -rf "$RES_DIR/Oatmeal_Oatmeal.bundle"   # keep re-runs idempotent: cp -R into an existing dir double-nests it
  cp -R "$RES_BUNDLE" "$RES_DIR/Oatmeal_Oatmeal.bundle"
  echo "embedded SwiftPM resource bundle in $RES_DIR"
else
  echo "WARN: no SwiftPM resource bundle at $RES_BUNDLE — app will crash at launch (missing icon resources)."
fi

# Bundle the frozen mr-cli onedir tree + the mr-capture helper into Resources/
# so the app is self-contained (PKG-BUNDLE/1). Frozen CLI may be absent in a
# dev-only source build — embed only when both artifacts exist.
if [[ -x "$FROZEN_CLI/mr-cli" && -x "$CAP_BIN" ]]; then
  mkdir -p "$RES_DIR"
  rm -rf "$RES_DIR/mr-cli"
  cp -R "$FROZEN_CLI" "$RES_DIR/mr-cli"
  cp -f "$CAP_BIN" "$RES_DIR/mr-capture"
  chmod +x "$RES_DIR/mr-capture"
  echo "embedded frozen mr-cli + mr-capture in $RES_DIR"
  # This script COPIES mr-capture, it never builds it. A helper older than its
  # own sources means someone edited capture/Sources and did not run
  # capture/build.sh — the bundle would ship the old binary silently, which is
  # exactly how an 11-day-old helper survived several reinstalls. Report it;
  # packaging/make_dmg.sh builds the helper first so this stays quiet there.
  NEWER_SRC="$(find ../capture/Sources -name '*.swift' -newer "$CAP_BIN" -print -quit 2>/dev/null || true)"
  if [[ -n "$NEWER_SRC" ]]; then
    echo "WARN: $CAP_BIN is OLDER than capture/Sources (e.g. $NEWER_SRC)."
    echo "WARN: the bundled mr-capture is stale — run capture/build.sh, or use packaging/make_dmg.sh."
  fi
else
  echo "WARN: frozen CLI ($FROZEN_CLI) or mr-capture ($CAP_BIN) missing — skipping embed; app is NOT self-contained (dev build)."
fi

# Adhoc codesign the bundle (deep: no embedded frameworks, but harmless).
codesign --force --deep --sign - "$APP"

echo "installed Oatmeal.app at $APP"
echo "note: drag the .app into /Applications to install it."
