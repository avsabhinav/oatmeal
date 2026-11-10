#!/usr/bin/env bash
# NOTARIZE-7b: Submit an ALREADY-SIGNED Oatmeal.app to Apple's notary service,
# block until the verdict is known, report it clearly, staple the ticket to
# the .app bundle itself on success, and prove the stapled app passes
# Gatekeeper. On rejection, print the full Apple rejection log (the single
# most valuable debugging artifact) and exit non-zero.
#
# Why staple the app itself (not just the DMG)? Apple's documented practice:
# the stapled ticket must travel WITH the artifact the user installs. A ticket
# stapled only to the DMG is lost the moment the user drags Oatmeal.app out
# of the mounted image into /Applications — offline Gatekeeper validation then
# fails with "the code is valid but does not seem to be an app" even though
# codesign is perfect. Stapling the app guarantees the ticket is inside the
# bundle (inside _CodeSignature) and survives the drag.
#
# Usage: bash packaging/notarize_app.sh /path/to/Oatmeal.app
#
# Requirements:
#   - NOTARY_PROFILE set (see packaging/signing.env.example; copy it to
#     packaging/signing.env, fill in real values, and source it). The
#     profile is a `notarytool` keychain profile created by the human with:
#       xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#         --team-id "$APPLE_TEAM_ID" --apple-id ... --password ...
#     This script ONLY uses the profile name — it never handles the Apple
#     ID or password, and nothing is hardcoded.
#   - The .app must already be signed by packaging/sign_app.sh (Developer ID,
#     hardened runtime).
#   - Network access: notarytool submits to Apple's notary service.
#
# What it does:
#   1. Validates ALL inputs (app exists and is a directory, NOTARY_PROFILE
#      set, notarytool + stapler available) and fails loudly before any
#      network call.
#   2. NOTARYTOOL requires a ZIP, not a bare .app directory, so it zips the
#      bundle with `ditto -c -k --keepParent` into a temp file, submits that
#      zip with JSON output, waiting up to 30 minutes, and removes the temp
#      zip on exit (trap) whatever the outcome.
#   3. On status "Accepted": staples the ticket to the ORIGINAL .app
#      (xcrun stapler staple — the ticket is fetched from Apple for the
#      bundle's cdhash, so stapling the unzipped app is correct), validates
#      the staple (xcrun stapler validate), and proves the app passes
#      Gatekeeper (spctl -a -t exec). Any failure in these steps is a hard
#      error.
#   4. On any other status (Invalid, Rejected, ...): prints the full JSON
#      result AND fetches the detailed log via `xcrun notarytool log`,
#      then exits non-zero.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

APP="${1:-$REPO_ROOT/menu-bar/.build/Release/Oatmeal.app}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# --- Validate ALL inputs BEFORE any network call (fail loudly). ------------
[[ -d "$APP" ]] || die "app bundle not found (or not a directory): $APP. Build it first with: bash menu-bar/install.sh, and sign it with: bash packaging/sign_app.sh"

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

echo "app:     $APP"
echo "profile: $PROFILE"

# --- Zip the bundle (notarytool cannot take a bare .app directory). ---------
# `ditto -c --keepParent` preserves the bundle structure (Oatmeal.app/...)
# exactly as it is on disk; the submission is identified by the app's cdhash,
# so the ticket Apple issues applies to the bundle itself.
ZIP="$(mktemp "${TMPDIR:-/tmp}/oatmeal-notary.XXXXXX").zip"
zip_cleanup() { rm -f "$ZIP"; }
trap zip_cleanup EXIT

echo "zipping $APP for notarization submission..."
ditto -c -k --keepParent "$APP" "$ZIP" \
  || die "ditto failed to zip $APP — cannot submit for notarization."

# --- Submit (JSON output, wait up to 30m) -----------------------------------
echo "submitting to Apple's notary service (this can take several minutes)..."
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" \
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
  echo "NOTARIZE_FAILED: $APP (status=$STATUS, submission=$SUBMISSION_ID)"
  die "notarization FAILED for $APP (status=$STATUS). See the Apple log above for the exact rejection reasons."
fi

# --- Accepted path: staple, validate, Gatekeeper ----------------------------
echo
echo "stapling the notarization ticket to $APP ..."
xcrun stapler staple "$APP" \
  || die "stapler staple failed for $APP (notarization itself was accepted — inspect the stapler output above)."

echo "validating the staple ..."
xcrun stapler validate "$APP" \
  || die "stapler validate failed for $APP — the stapled ticket is invalid."

echo "checking Gatekeeper (spctl) ..."
SPCTL_OUT="$(xcrun spctl -a -t exec -v "$APP" 2>&1)" \
  && SPCTL_RC=0 \
  || SPCTL_RC=$?
printf '%s\n' "$SPCTL_OUT"
if [[ "$SPCTL_RC" -ne 0 ]] || ! grep -q "accepted" <<<"$SPCTL_OUT"; then
  die "spctl rejected the stapled app (Gatekeeper check failed): $APP"
fi

echo
echo "NOTARIZE_OK: $APP (status=Accepted, submission=$SUBMISSION_ID, stapled + Gatekeeper accepted)"
echo "OK: $APP notarized, stapled, and accepted by Gatekeeper."
