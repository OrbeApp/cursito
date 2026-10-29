#!/usr/bin/env bash
#
# build-app.sh — builds a universal Cursito.app into ./build.
#
# Usage:
#   scripts/build-app.sh             # build/Cursito.app, signed ad hoc (fine on your own Macs)
#   scripts/build-app.sh --install   # also copies it to /Applications
#   scripts/build-app.sh --zip       # also writes build/Cursito.zip, ready to notarize
#
# Set CODESIGN_IDENTITY="Developer ID Application: …" to sign for distribution
# (hardened runtime + timestamp), then notarize the zip; see the README.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Cursito.app"
INSTALL=0
ZIP=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    -h|--help) awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

cd "$ROOT"
echo "Building release binary…"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Cursito" "$APP/Contents/MacOS/Cursito"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp scripts/sync-cursor.sh scripts/update-repos.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "Signing with ${CODESIGN_IDENTITY}…"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  echo "Signing ad hoc (set CODESIGN_IDENTITY to sign for distribution)…"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

if [ "$ZIP" -eq 1 ]; then
  rm -f "$ROOT/build/Cursito.zip"
  ditto -c -k --keepParent "$APP" "$ROOT/build/Cursito.zip"
  echo "Wrote build/Cursito.zip"
fi

if [ "$INSTALL" -eq 1 ]; then
  osascript -e 'quit app id "com.orbeapp.cursito"' >/dev/null 2>&1 || true
  rm -rf /Applications/Cursito.app
  ditto "$APP" /Applications/Cursito.app
  echo "Installed /Applications/Cursito.app"
fi

echo "Done: $APP"
