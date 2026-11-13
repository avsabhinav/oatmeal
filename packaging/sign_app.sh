#!/usr/bin/env bash
# NOTARIZE-2: Re-sign an already-assembled Oatmeal.app with a Developer ID
# Application certificate (hardened runtime + correct entitlements), signing
# INSIDE-OUT in the order Apple requires: leaf binaries first, the mr-cli
# tree, and the .app bundle LAST. No --deep (deprecated for signing; it
# hides inner-binary errors that later break notarization).
#
# Usage: bash packaging/sign_app.sh [path/to/Oatmeal.app]
#        (default: menu-bar/.build/Release/Oatmeal.app)
#
# Requirements:
#   - DEVELOPER_ID_APP set (see packaging/signing.env.example; copy it to
#     packaging/signing.env, fill in real values, and source it). No
#     certificate name, Team ID, or Apple ID is hardcoded anywhere.
#   - The identity must be in the keychain:
#     security find-identity -v -p codesigning
#   - Network access: --timestamp contacts Apple's timestamp authority.
#     This is REQUIRED for a valid Developer ID signature (and notarization
#     needs it). Do NOT "fix" it away or switch to ad-hoc timestamps.
#
# What it does:
#   1. Validates ALL inputs (bundle exists, identity set + in keychain,
#      entitlements files present) and fails loudly before signing ANYTHING.
#   2. Signs the leaf Mach-O binaries:
#        Contents/MacOS/Oatmeal           (app.entitlements)
#        Contents/Resources/mr-capture    (helper.entitlements)
#   3. Signs every Mach-O file under Contents/Resources/mr-cli/ individually
#      (app.entitlements). Non-Mach-O files (Python sources, metallib, data,
#      PNGs) are detected with `file -b` and skipped — we never run one
#      codesign per file blindly across the ~3000-file tree.
#   4. Signs the Contents/Resources/mr-cli DIRECTORY tree itself, as a
#      bundle-less tree: a plain directory is not a bundle type, and codesign
#      rejects --entitlements on non-bundle resources, so it is signed
#      WITHOUT an entitlements file by design.
#   5. Signs Oatmeal.app LAST, with --options runtime (notarization requires
#      the hardened runtime) --timestamp and app.entitlements.
#   6. Verifies: codesign --verify --deep --strict --verbose=2 (the
#      --deep here is for VERIFICATION, which is fine), plus codesign -dv,
#      asserting "Authority=Developer ID Application" and the hardened-
#      runtime flag "flags=0x10000(runtime)".
#
# Idempotent: every codesign uses --force, so a second run on the same
# bundle succeeds.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

APP="${1:-$REPO_ROOT/menu-bar/.build/Release/Oatmeal.app}"
APP_ENT="$REPO_ROOT/packaging/entitlements/app.entitlements"
HELPER_ENT="$REPO_ROOT/packaging/entitlements/helper.entitlements"

# The keychain holding the signing identity. Override with KEYCHAIN_PATH if the
# identity lives somewhere other than the default login keychain.
KEYCHAIN_PATH="${KEYCHAIN_PATH:-$(security default-keychain 2>/dev/null | tr -d ' "')}"
[[ -n "$KEYCHAIN_PATH" && -f "$KEYCHAIN_PATH" ]] || KEYCHAIN_PATH=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- Validate ALL inputs BEFORE signing anything (fail loudly). ------------
[[ -d "$APP" ]] || die "app bundle not found (or not a directory): $APP"

IDENTITY="${DEVELOPER_ID_APP:-}"
[[ -n "$IDENTITY" ]] || die "DEVELOPER_ID_APP is unset or empty. See packaging/signing.env.example (copy it to packaging/signing.env with real values, then: source packaging/signing.env)."

[[ -f "$APP_ENT" ]]    || die "app entitlements file missing: $APP_ENT"
[[ -f "$HELPER_ENT" ]] || die "helper entitlements file missing: $HELPER_ENT"

command -v codesign >/dev/null 2>&1 || die "codesign not found (install the Xcode command line tools)."
command -v file     >/dev/null 2>&1 || die "file(1) not found (required to detect Mach-O payloads)."

# Entitlements must be parseable by codesign's AMFI parser, which is STRICTER
# than plutil: an XML comment containing "--" lints OK but makes codesign die
# with "AMFIUnserializeXML: syntax error" — and it fails only once the real
# (slow, ~3000-file) signing run has already started. Catch it up front with
# the same parser codesign uses: sign a throwaway copy of /bin/echo.
ENT_PROBE="$(mktemp -d "${TMPDIR:-/tmp}/mr-entprobe.XXXXXX")"
trap 'rm -rf "$ENT_PROBE"' EXIT
for ent in "$APP_ENT" "$HELPER_ENT"; do
  cp /bin/echo "$ENT_PROBE/probe"
  if ! codesign --force --sign - --entitlements "$ent" "$ENT_PROBE/probe" >/dev/null 2>&1; then
    echo "--- codesign said: ---" >&2
    cp /bin/echo "$ENT_PROBE/probe"
    codesign --force --sign - --entitlements "$ent" "$ENT_PROBE/probe" 2>&1 >&2 | head -5 >&2
    die "entitlements file is not parseable by codesign: $ent (a '--' inside an XML comment lints OK but breaks AMFI; reword the comment)"
  fi
  rm -f "$ENT_PROBE/probe"
done
rm -rf "$ENT_PROBE"
trap - EXIT

echo "identity: $IDENTITY"
echo "bundle:   $APP"

# --- Keep the keychain unlocked for the whole run. --------------------------
# Signing ~135 Mach-O files takes a while, and the login keychain relocks after
# its sleep timeout. When it relocks mid-run, codesign fails with the extremely
# unhelpful "errSecInternalComponent" (the same file signs fine on its own,
# which makes this look like a per-file problem when it is a lock problem).
# Extend the timeout for the duration of this script and try to unlock up
# front. `security unlock-keychain` with no -p prompts via the GUI if needed;
# if it fails we continue, because signing may still succeed on an unlocked
# keychain and the verify step below will catch a real failure.
if [[ -n "${KEYCHAIN_PATH:-}" ]]; then
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >/dev/null 2>&1 \
    && echo "keychain: extended unlock timeout to 6h ($KEYCHAIN_PATH)" \
    || echo "WARN: could not extend keychain timeout for $KEYCHAIN_PATH" >&2
  security unlock-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi

if ! security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$IDENTITY" >/dev/null; then
  echo "WARN: '$IDENTITY' is NOT in the keychain's valid codesigning identities." >&2
  echo "WARN: list your identities with: security find-identity -v -p codesigning" >&2
  exit 1
fi

MACHO_SIGNED=0

# sign_bin <path> <entitlements> — sign one Mach-O binary, hardened runtime.
sign_bin() {
  local bin="$1" ent="$2"
  [[ -f "$bin" ]] || die "expected binary missing: $bin"
  echo "signing: $bin"
  codesign --force --options runtime --timestamp \
    --entitlements "$ent" \
    --sign "$IDENTITY" "$bin"
  MACHO_SIGNED=$((MACHO_SIGNED + 1))
}

# --- 1) Leaf Mach-O binaries ------------------------------------------------
MACOS_BIN="$APP/Contents/MacOS/Oatmeal"
CAP_BIN="$APP/Contents/Resources/mr-capture"
CLI_DIR="$APP/Contents/Resources/mr-cli"

sign_bin "$MACOS_BIN" "$APP_ENT"

# mr-capture may be absent in a dev build (menu-bar/install.sh warns and
# continues without it) — warn and skip rather than half-sign.
#
# Sign the helper with an EXPLICIT helper-of-app identifier (com.oatmeal.app.mr-capture)
# so its code identity cannot look like a separate application: a binary with its
# own standalone identifier becomes its own TCC subject and shows up as a second
# row in System Settings ▸ Privacy.
if [[ -f "$CAP_BIN" ]]; then
  echo "signing: $CAP_BIN"
  codesign --force --options runtime --timestamp \
    --identifier com.oatmeal.app.mr-capture \
    --entitlements "$HELPER_ENT" \
    --sign "$IDENTITY" "$CAP_BIN"
  MACHO_SIGNED=$((MACHO_SIGNED + 1))
else
  echo "WARN: $CAP_BIN missing — skipping helper (dev build without embedded helper?)."
fi

# --- 2) mr-cli tree: every Mach-O file individually --------------------------
if [[ -d "$CLI_DIR" ]]; then
  while IFS= read -r bin; do
    # `file -b` gives e.g. "Mach-O 64-bit executable arm64" / "... shared library".
    # Skip everything else (Python, metallib, data, images) — never sign it.
    if file -b "$bin" | grep -q "Mach-O"; then
      echo "signing: $bin"
      codesign --force --options runtime --timestamp \
        --entitlements "$APP_ENT" \
        --sign "$IDENTITY" "$bin"
      MACHO_SIGNED=$((MACHO_SIGNED + 1))
    fi
  done < <(find "$CLI_DIR" -type f)
else
  echo "WARN: $CLI_DIR missing — skipping CLI tree (dev build without embedded frozen CLI?)."
fi

# --- 3) mr-cli tree: DELETE any stray _CodeSignature, then sign mr-cli itself -
# DO NOT sign $CLI_DIR as a directory. It is a PyInstaller ONEDIR data tree, not
# a bundle, but `codesign <dir>` still writes mr-cli/_CodeSignature/ into it and
# that makes the already-signed entry executable (mr-cli/mr-cli) inconsistent:
# Apple's notary service then rejects the whole DMG with
#   "mr-cli/mr-cli: The signature of the binary is invalid."
# The individual Mach-O payloads signed in step 2 are what notarization needs.
# Any _CodeSignature left behind by an earlier run (or by PyInstaller) must be
# removed, or it re-invalidates the tree from the previous attempt.
if [[ -d "$CLI_DIR" ]]; then
  if [[ -e "$CLI_DIR/_CodeSignature" ]]; then
    echo "removing stale $CLI_DIR/_CodeSignature (would invalidate mr-cli)"
    rm -rf "$CLI_DIR/_CodeSignature"
  fi
fi

# --- 4) The .app bundle LAST -------------------------------------------------
echo "signing: $APP"
codesign --force --options runtime --timestamp \
  --entitlements "$APP_ENT" \
  --sign "$IDENTITY" "$APP"

# --- 5) Verify ---------------------------------------------------------------
VERIFY_OUT="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)" \
  || { printf '%s\n' "$VERIFY_OUT" >&2; die "codesign --verify --deep --strict failed for $APP"; }
echo "$VERIFY_OUT"

INFO_OUT="$(codesign -dv --verbose=4 "$APP" 2>&1)" \
  || { printf '%s\n' "$INFO_OUT" >&2; die "codesign -dv failed for $APP"; }
echo "$INFO_OUT"

grep -Fq "Authority=Developer ID Application" <<<"$INFO_OUT" \
  || die "verification failed: signature does not carry 'Authority=Developer ID Application'."
grep -Fq "flags=0x10000(runtime)" <<<"$INFO_OUT" \
  || die "verification failed: hardened runtime flag 'flags=0x10000(runtime)' is missing."

# --- 6) Summary ---------------------------------------------------------------
echo "OK: signed $MACHO_SIGNED Mach-O binaries inside-out, then $APP last; verification passed (Developer ID authority + hardened runtime)."
