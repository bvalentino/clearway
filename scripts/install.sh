#!/usr/bin/env bash
# Build Clearway in Release configuration and install to /Applications.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

PRODUCT_NAME="Clearway"

# Resolve BUILT_PRODUCTS_DIR once, then build.
BUILD_DIR=$(xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release -destination 'platform=macOS' \
  PRODUCT_NAME="$PRODUCT_NAME" PRODUCT_MODULE_NAME=Clearway \
  -showBuildSettings 2>/dev/null | grep -m1 '^\s*BUILT_PRODUCTS_DIR' | awk '{print $3}')

echo "==> Building $PRODUCT_NAME (Release)..."
xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release -destination 'platform=macOS' \
  PRODUCT_NAME="$PRODUCT_NAME" PRODUCT_MODULE_NAME=Clearway build -quiet

APP_PATH="$BUILD_DIR/$PRODUCT_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found."
  exit 1
fi

INSTALL_PATH="/Applications/$PRODUCT_NAME.app"

echo "==> Installing to $INSTALL_PATH..."
if [ -d "$INSTALL_PATH" ]; then
  rm -rf "$INSTALL_PATH"
fi
cp -R "$APP_PATH" "$INSTALL_PATH"

echo "==> Installed $PRODUCT_NAME to /Applications."
