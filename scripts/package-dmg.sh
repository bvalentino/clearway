#!/usr/bin/env bash
# Package a notarized Clearway.app into a signed, notarized, stapled DMG.
#
# Usage:
#   ./scripts/package-dmg.sh [path/to/Clearway-*-notarized.zip]
#
# If no argument is given, uses the most recent -notarized.zip in release/.
# Run ./scripts/notarize.sh first to produce the stapled input.
#
# Required environment:
#   ASC_API_KEY_PATH  absolute path to your App Store Connect API .p8 file
set -euo pipefail

: "${ASC_API_KEY_PATH:?Set ASC_API_KEY_PATH to your App Store Connect API .p8 file path}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RELEASE_DIR="$PROJECT_DIR/release"

SIGN_IDENTITY="Developer ID Application: Bruno Valentino (76AEQBHY3K)"
ASC_KEY_ID="WA4BFSM2PC"
ASC_ISSUER_ID="69a6de7c-c161-47e3-e053-5b8c7c11a4d1"
VOLUME_NAME="Clearway"

if [ ! -f "$ASC_API_KEY_PATH" ]; then
  echo "Error: ASC_API_KEY_PATH points to a file that doesn't exist: $ASC_API_KEY_PATH"
  exit 1
fi

# Pick the notarized zip: argument, or newest in release/
if [ $# -ge 1 ]; then
  ZIP_PATH="$1"
else
  ZIP_PATH=$(ls -t "$RELEASE_DIR"/Clearway-*-notarized.zip 2>/dev/null | head -1 || true)
  if [ -z "$ZIP_PATH" ]; then
    echo "Error: no -notarized.zip in $RELEASE_DIR."
    echo "       Run ./scripts/notarize.sh first, or pass a zip path as argument."
    exit 1
  fi
fi

if [ ! -f "$ZIP_PATH" ]; then
  echo "Error: $ZIP_PATH not found."
  exit 1
fi

# DMG name = zip name minus the -notarized suffix
BASE=$(basename "$ZIP_PATH" .zip)
BASE=${BASE%-notarized}
DMG_PATH="$RELEASE_DIR/$BASE.dmg"

# Staging dir holds the .app + an Applications symlink for the DMG layout
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "==> Extracting $(basename "$ZIP_PATH")..."
ditto -x -k "$ZIP_PATH" "$STAGING"

APP_PATH=$(find "$STAGING" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
  echo "Error: no .app inside $ZIP_PATH"
  exit 1
fi

# Require the .app to already be stapled (notarize.sh handles this)
if ! xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
  echo "Error: $(basename "$APP_PATH") is not stapled."
  echo "       Run ./scripts/notarize.sh first."
  exit 1
fi

# Drag-to-Applications target
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"

echo "==> Creating $(basename "$DMG_PATH")..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "==> Signing DMG..."
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

echo "==> Submitting DMG to notarization service..."
SUBMIT_LOG=$(mktemp)
set +e
xcrun notarytool submit "$DMG_PATH" \
  --key "$ASC_API_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait 2>&1 | tee "$SUBMIT_LOG"
set -e

FINAL_STATUS=$(grep -E '^\s*status:' "$SUBMIT_LOG" | tail -1 | awk '{print $2}')
SUBMISSION_ID=$(grep -E '^\s*id:' "$SUBMIT_LOG" | head -1 | awk '{print $2}')

if [ "$FINAL_STATUS" != "Accepted" ]; then
  echo ""
  echo "!!! DMG notarization failed: status=$FINAL_STATUS"
  echo "!!! Fetching log for submission $SUBMISSION_ID..."
  echo ""
  xcrun notarytool log "$SUBMISSION_ID" \
    --key "$ASC_API_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" || true
  exit 1
fi

echo "==> Stapling DMG..."
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying with Gatekeeper..."
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

echo ""
echo "==> Done."
echo "    DMG: $DMG_PATH"
echo "    Size: $(du -h "$DMG_PATH" | awk '{print $1}')"
echo "    Distribute this file."
