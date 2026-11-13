#!/usr/bin/env bash
# Build mr-capture into a signed-release binary with an embedded Info.plist
# (the micro usage descriptions) so macOS shows proper permission prompts.
#
# Usage: ./build.sh
# Produces: capture/.build/release/mr-capture
set -euo pipefail
cd "$(dirname "$0")"

# Fallback for restrictive shells (e.g. the DSH tool sandbox, where writes to
# ~/Library/org.swift.swiftpm and the system temp dir are denied): redirect the
# Swift toolchain caches to workspace-local dirs. No-op in a normal terminal.
if ! touch "$HOME/Library/org.swift.swiftpm/.probe" 2>/dev/null \
   || ! touch "${TMPDIR:-/tmp}/.probe" 2>/dev/null; then
  mkdir -p .tmp .modcache .swiftpm-cache
  export TMPDIR="$(pwd)/.tmp"
  export CLANG_MODULE_CACHE_PATH="$(pwd)/.modcache"
  export SWIFTPM_CACHE_DIR="$(pwd)/.swiftpm-cache"
fi
rm -f "$HOME/Library/org.swift.swiftpm/.probe" "${TMPDIR:-/tmp}/.probe" 2>/dev/null || true

PLIST="$(pwd)/Info.plist"
BIN=".build/release/mr-capture"

echo "==> swift build -c release (embedding Info.plist)"
# --disable-sandbox: needed when run inside the DSH tool sandbox (sandbox-exec is
# blocked there); harmless and a no-op when invoked from a normal terminal.
swift build --disable-sandbox -c release \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"

echo "==> verifying embedded plist section"
otool -s __TEXT __info_plist "$BIN" | head -20

echo "==> codesign (adhoc, identifier com.oatmeal.app.mr-capture)"
# Sign with the explicit helper identifier so a locally built helper carries
# the same code identity as the shipped one (a helper of Oatmeal.app, not a
# standalone TCC subject).
codesign --force --sign - --identifier com.oatmeal.app.mr-capture "$BIN"

echo "==> done: $BIN"
echo "==> run with: $BIN --out <dir>"
