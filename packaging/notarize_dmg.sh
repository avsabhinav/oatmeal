#!/usr/bin/env bash
# NOTARIZE-3: Submit an ALREADY-SIGNED Oatmeal DMG to Apple's notary service,
# block until the verdict is known, report it clearly, staple the ticket on
# success, and prove the stapled image passes Gatekeeper. On rejection,
# print the full Apple rejection log (the single most valuable debugging
# artifact) and exit non-zero.
#
# Usage: bash packaging/notarize_dmg.sh [path/to/Oatmeal.dmg]
#        (default: dist/Oatmeal-0.1.1.dmg — but the caller should pass the
#        built DMG path explicitly; the default is fixed only because the
#        caller normally knows the exact path.)
#
# Requirements:
#   - NOTARY_PROFILE set (see packaging/signing.env.example; copy it to
#     packaging/signing.env, fill in real values, and source it). The
#     profile is a `notarytool` keychain profile created by the human with:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#         --team-id "$APPLE_TEAM_ID" --apple-id ... --password ...
#     This script ONLY uses the profile name — it never handles the Apple
#     ID or password, and nothing is hardcoded.
#   - The DMG must already be signed by packaging/sign_app.sh (Developer ID,
#     hardened runtime) and built by packaging/make_dmg.sh.
#   - Network access: notarytool submits to Apple's notary service.
#
# What it does:
#   1. Validates ALL inputs (DMG exists, NOTARY_PROFILE set, notarytool +
#      stapler available) and fails loudly before any network call.
#   2. Submits with JSON output, waiting up to 30 minutes (a ~1.4 GB app
#      inside a ~200 MB DMG can take a while to process).
#   3. On status "Accepted": staples the ticket (xcrun stapler staple),
#      validates the staple (xcrun stapler validate), and proves the image
#      passes Gatekeeper (spctl -a -t open with primary-signature context).
#      Any failure in these steps is a hard error.
#   4. On any other status (Invalid, Rejected, ...): prints the full JSON
#      result AND fetches the detailed log via `xcrun notarytool log`,
#      then exits non-zero.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# The caller should pass the built DMG path explicitly; this default is a
# convenience fallback matching the current version in pyproject.toml.
DMG="${1:-$REPO_ROOT/dist/Oatmeal-0.1.1.dmg}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- Validate ALL inputs BEFORE any network call (fail loudly). ------------
[[ -f "$DMG" ]] || die "DMG not found (or not a file): $DMG. Build it first with: bash packaging/make_dmg.sh, and sign it with: bash packaging/sign_app.sh"

PROFILE="${NOTARY_PROFILE:-}"
[[ -n "$PROFILE" ]] \
  || die "NOTARY_PROFILE is unset or empty. See packaging/signing.env.example (copy it to packaging/signing.env with real values, create the profile with: xcrun notarytool store-credentials \"\$NOTARY_PROFILE\" --team-id \"\$APPLE_TEAM_ID\" --apple-id ... --password ..., then: source packaging/signing.env)."

command -v python3 >/dev/null 2>&1 || die "python3 not found (required to parse notarytool JSON output)."
command -v xcrun   >/dev/null 2>&1 || die "xcrun not found (install the Xcode command line tools)."
xcrun notarytool --version >/dev/null 2>&1 || die "notarytool not available via xcrun (install Xcode command line tools)."
# NOTE: do NOT probe stapler with `xcrun stapler version` — stapler has no
# `version` subcommand and exits 64 after printing usage, which would abort a
# perfectly healthy machine with a misleading "install Xcode" error.
# `xcrun -f` locates the tool without running it.
xcrun -f stapler >/dev/null 2>&1 \
  || die "stapler not available via xcrun (install Xcode command line tools)."

echo "dmg:    $DMG"
echo "profile: $PROFILE"

# --- Submit (JSON output, wait up to 30m) -----------------------------------
echo "submitting to Apple's notary service (this can take several minutes)..."
SUBMIT_OUT="$(xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE" \
  --wait --timeout 30m \
  --output-format json 2>&1)" \
  || { printf '%s\n' "$SUBMIT_OUT" >&2; die "notarytool submit failed (see output above)."; }

# notarytool writes human-readable chatter ("Successfully received ...",
# progress lines, and CoreData warnings like
#   notarytool[1234:5678] Error: stepSQLStatement:... DB=.../Cache.db
# to STDERR, and the JSON result to STDOUT. The submit call below merges both
# (2>&1) into one buffer so the warnings are still visible on failure.
#
# That merged stream is NOT valid JSON, and `data.find("{")` is not enough to
# recover it: notarytool's chatter itself contains braces, so an index found
# that way can land mid-warning and leave trailing text after the object,
# which makes json.loads die with "Extra data: line 2 column 1" — an
# inscrutable failure late in a long build, even though Apple had already
# accepted the submission.
#
# Correct approach: try json.JSONDecoder().raw_decode at every "{", which
# consumes exactly one object and reports where it ended. The first candidate
# that decodes to a dict containing the requested key wins. Decoding is exact
# (not a regex), so a brace inside a warning message simply fails to decode and
# is skipped, and trailing text after the object is never consumed.
parse_field() {
  # parse_field <key> — extract a top-level string field from SUBMIT_OUT's JSON.
  python3 -c '
import json, sys
data = sys.stdin.read()
key = sys.argv[1]
decoder = json.JSONDecoder()
for idx, ch in enumerate(data):
    if ch != "{":
        continue
    try:
        obj, _ = decoder.raw_decode(data, idx)
    except ValueError:
        continue
    if isinstance(obj, dict) and key in obj:
        value = obj[key]
        if value is not None:
            print(value)
            sys.exit(0)
sys.exit(1)
' "$1" <<<"$SUBMIT_OUT"
}

SUBMISSION_ID="$(parse_field id)" \
  || die "could not extract submission id from notarytool JSON output."
STATUS="$(parse_field status)" \
  || die "could not extract status from notarytool JSON output."

echo "submission id: $SUBMISSION_ID"
echo "status:        $STATUS"

# --- Rejected / invalid path: NEVER swallow the log -------------------------
if [[ "$STATUS" != "Accepted" ]]; then
  echo
  echo "=== Full notarytool JSON result ==="
  printf '%s\n' "$SUBMIT_OUT"
  echo
  echo "=== Detailed Apple rejection log (notarytool log $SUBMISSION_ID) ==="
  if ! xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE"; then
    echo "WARN: could not fetch the detailed log (see above for the raw result)." >&2
  fi
  echo
  echo "NOTARIZE_FAILED: $DMG (status=$STATUS, submission=$SUBMISSION_ID)"
  die "notarization FAILED for $DMG (status=$STATUS). See the Apple log above for the exact rejection reasons."
fi

# --- Accepted path: staple, validate, Gatekeeper ----------------------------
echo
echo "stapling the notarization ticket to $DMG ..."
xcrun stapler staple "$DMG" \
  || die "stapler staple failed for $DMG (notarization itself was accepted — inspect the stapler output above)."

echo "validating the staple ..."
xcrun stapler validate "$DMG" \
  || die "stapler validate failed for $DMG — the stapled ticket is invalid."

# --- Gatekeeper check: on the APP INSIDE the image, not the image file. ------
# Do NOT use `spctl -a -t open --context context:primary-signature "$DMG"` here.
# That context demands a code signature ON THE .dmg FILE, and this pipeline
# never code-signs the image — make_dmg.sh only builds it with hdiutil, and
# sign_app.sh signs the .app. The check therefore always fails with
#   "<dmg>: rejected  source=no usable signature"
# even when the image is correctly notarized and stapled, aborting a build that
# actually succeeded (observed: DMG staple validated OK, app inside notarized
# and Gatekeeper-accepted, yet the build reported "notarization FAILED").
#
# What actually decides whether a user can run this artifact is Gatekeeper's
# verdict on the .app they drag out of the image. So mount the image read-only,
# and require the inner app to be Developer ID signed, stapled, and accepted.
# The mount is ALWAYS detached via a trap, even on failure.
echo "checking Gatekeeper on the app INSIDE the image ..."
MOUNT_PT="$(mktemp -d "${TMPDIR:-/tmp}/mr-notary-mount.XXXXXX")"
MOUNTED=0
mount_cleanup() {
  if [[ "${MOUNTED:-0}" == "1" ]]; then
    hdiutil detach "$MOUNT_PT" >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_PT"
}
trap mount_cleanup EXIT

hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_PT" >/dev/null 2>&1 \
  || die "could not mount $DMG read-only to verify the app inside it."
MOUNTED=1

INNER_APP="$MOUNT_PT/Oatmeal.app"
[[ -d "$INNER_APP" ]] \
  || die "Oatmeal.app not found inside $DMG (mounted at $MOUNT_PT)."

INNER_CODESIGN="$(codesign -dv --verbose=4 "$INNER_APP" 2>&1)" \
  || die "codesign -dv failed on the app inside $DMG."
grep -q "Authority=Developer ID Application" <<<"$INNER_CODESIGN" \
  || die "the app inside $DMG is NOT Developer ID signed (no 'Authority=Developer ID Application')."

xcrun stapler validate "$INNER_APP" >/dev/null 2>&1 \
  || die "the app inside $DMG has no valid stapled notarization ticket — it would be rejected on a fresh Mac."

SPCTL_OUT="$(xcrun spctl -a -t exec -v "$INNER_APP" 2>&1)" \
  && SPCTL_RC=0 \
  || SPCTL_RC=$?
printf '%s\n' "$SPCTL_OUT"
if [[ "$SPCTL_RC" -ne 0 ]] || ! grep -q "accepted" <<<"$SPCTL_OUT"; then
  die "spctl rejected the app inside $DMG (Gatekeeper check failed): $INNER_APP"
fi
echo "inner app: signed, stapled, and Gatekeeper accepted."

echo
echo "NOTARIZE_OK: $DMG (status=Accepted, submission=$SUBMISSION_ID, stapled; inner app signed + stapled + Gatekeeper accepted)"
echo "OK: $DMG notarized, stapled, and its app accepted by Gatekeeper."
