#!/usr/bin/env bash
# Release stage 1: clean Release build of HEAD, zipped as release/Clearway-<version>-<sha>.zip.
#
# Run through ./scripts/release.sh; run directly only to resume a release whose
# version bump is already committed.
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

clearway_read_versions
# The app is stamped with HEAD's hash, so HEAD has to be what gets built.
clearway_require_clean_tree

BASE=$(clearway_artifact_base)

BUILD_DIR=$(xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release -destination 'platform=macOS' \
  APP_PRODUCT_NAME="$PRODUCT_NAME" \
  -showBuildSettings 2>/dev/null | grep -m1 '^\s*BUILT_PRODUCTS_DIR' | awk '{print $3}')

echo "==> Building $BASE (build $CURRENT_PROJECT_VERSION) Release..."
# Always clean: an incremental build once re-signed cway but left the stale copy
# embedded in the app, and that copy failed notarization.
xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release -destination 'platform=macOS' \
  APP_PRODUCT_NAME="$PRODUCT_NAME" clean build -quiet

APP_PATH="$BUILD_DIR/$PRODUCT_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found."
  exit 1
fi

# Strip extended attributes that cause Gatekeeper issues when zipped
xattr -cr "$APP_PATH"

mkdir -p "$RELEASE_DIR"
ZIP_PATH="$RELEASE_DIR/$BASE.zip"

# Use ditto for macOS-friendly zip that preserves resource forks and code signatures
echo "==> Zipping $(basename "$ZIP_PATH")..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Built: $ZIP_PATH ($(du -h "$ZIP_PATH" | awk '{print $1}'))"
