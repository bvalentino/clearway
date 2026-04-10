#!/usr/bin/env bash
# Notarize and staple a Clearway release zip.
#
# Usage:
#   ./scripts/notarize.sh [path/to/Clearway-*.zip]
#
# If no argument is given, uses the most recent zip in release/.
# Run ./scripts/release.sh first to produce the signed zip.
#
# Required environment:
#   ASC_API_KEY_PATH  absolute path to your App Store Connect API .p8 file
#                     (keep this OUTSIDE the repo, e.g. ~/.appstoreconnect/AuthKey_XXXXX.p8)
set -euo pipefail

: "${ASC_API_KEY_PATH:?Set ASC_API_KEY_PATH to your App Store Connect API .p8 file path}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RELEASE_DIR="$PROJECT_DIR/release"

ASC_KEY_ID="WA4BFSM2PC"
ASC_ISSUER_ID="69a6de7c-c161-47e3-e053-5b8c7c11a4d1"

if [ ! -f "$ASC_API_KEY_PATH" ]; then
  echo "Error: ASC_API_KEY_PATH points to a file that doesn't exist: $ASC_API_KEY_PATH"
  exit 1
fi

# Pick the zip to notarize: argument, or newest in release/
if [ $# -ge 1 ]; then
  ZIP_PATH="$1"
else
  ZIP_PATH=$(ls -t "$RELEASE_DIR"/Clearway-*.zip 2>/dev/null | head -1 || true)
  if [ -z "$ZIP_PATH" ]; then
    echo "Error: no zip found in $RELEASE_DIR."
    echo "       Run ./scripts/release.sh first, or pass a zip path as an argument."
    exit 1
  fi
fi

if [ ! -f "$ZIP_PATH" ]; then
  echo "Error: $ZIP_PATH not found."
  exit 1
fi

echo "==> Submitting $(basename "$ZIP_PATH") to notarization service..."
SUBMIT_LOG=$(mktemp)
set +e
xcrun notarytool submit "$ZIP_PATH" \
  --key "$ASC_API_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait 2>&1 | tee "$SUBMIT_LOG"
set -e

FINAL_STATUS=$(grep -E '^\s*status:' "$SUBMIT_LOG" | tail -1 | awk '{print $2}')
SUBMISSION_ID=$(grep -E '^\s*id:' "$SUBMIT_LOG" | head -1 | awk '{print $2}')

if [ "$FINAL_STATUS" != "Accepted" ]; then
  echo ""
  echo "!!! Notarization failed: status=$FINAL_STATUS"
  echo "!!! Fetching detailed log for submission $SUBMISSION_ID..."
  echo ""
  xcrun notarytool log "$SUBMISSION_ID" \
    --key "$ASC_API_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" || true
  exit 1
fi

# Unpack to staple the ticket onto the .app, then re-zip.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Unpacking to staple..."
ditto -x -k "$ZIP_PATH" "$WORK_DIR"

APP_PATH=$(find "$WORK_DIR" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
  echo "Error: couldn't find a .app bundle inside $ZIP_PATH"
  exit 1
fi

echo "==> Stapling $(basename "$APP_PATH")..."
xcrun stapler staple "$APP_PATH"

echo "==> Verifying with Gatekeeper..."
spctl -a -vv "$APP_PATH"

STAPLED_ZIP="${ZIP_PATH%.zip}-notarized.zip"
echo "==> Repackaging as $(basename "$STAPLED_ZIP")..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$STAPLED_ZIP"

echo ""
echo "==> Done."
echo "    Notarized zip: $STAPLED_ZIP"
echo "    Distribute this one — not the original."
