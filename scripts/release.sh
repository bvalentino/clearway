#!/usr/bin/env bash
# Build Clearway in Release configuration and produce a distributable zip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

PRODUCT_NAME="Clearway"
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | awk -F'"' '{print $2}')
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Resolve BUILT_PRODUCTS_DIR once, then build.
BUILD_DIR=$(xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release -destination 'platform=macOS' \
  PRODUCT_NAME="$PRODUCT_NAME" PRODUCT_MODULE_NAME=Clearway \
  -showBuildSettings 2>/dev/null | grep -m1 '^\s*BUILT_PRODUCTS_DIR' | awk '{print $3}')

echo "==> Building $PRODUCT_NAME v$VERSION ($COMMIT) Release..."
xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Release -destination 'platform=macOS' \
  PRODUCT_NAME="$PRODUCT_NAME" PRODUCT_MODULE_NAME=Clearway build -quiet

APP_PATH="$BUILD_DIR/$PRODUCT_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found."
  exit 1
fi

# Strip extended attributes that cause Gatekeeper issues when zipped
xattr -cr "$APP_PATH"

# Create zip in project root
OUTPUT_DIR="$PROJECT_DIR/release"
mkdir -p "$OUTPUT_DIR"
ZIP_NAME="${PRODUCT_NAME}-${VERSION}-${COMMIT}.zip"
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"

# Use ditto for macOS-friendly zip that preserves resource forks and code signatures
echo "==> Packaging $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Release ready: $ZIP_PATH"
echo "    Size: $(du -h "$ZIP_PATH" | awk '{print $1}')"
echo ""
echo "This zip is signed but not yet notarized — do not distribute as-is."
echo "Next steps:"
echo "  ./scripts/notarize.sh      # notarize + staple the .app"
echo "  ./scripts/package-dmg.sh   # wrap the stapled .app in a signed, notarized DMG"
