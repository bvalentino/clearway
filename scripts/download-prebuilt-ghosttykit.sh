#!/usr/bin/env bash
# Download a pre-built GhosttyKit.xcframework from GitHub releases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GHOSTTY_SHA="$(git -C "$PROJECT_DIR/ghostty" rev-parse HEAD)"
TAG="xcframework-$GHOSTTY_SHA"
ARCHIVE="GhosttyKit.xcframework.tar.gz"
OUTPUT_DIR="$PROJECT_DIR/ghostty/macos/GhosttyKit.xcframework"
URL="https://github.com/bvalentino/ghostty/releases/download/$TAG/$ARCHIVE"

echo "==> Downloading GhosttyKit for ghostty $GHOSTTY_SHA"
curl --fail --show-error --location \
  --retry 3 --retry-delay 5 --retry-all-errors \
  -o "$ARCHIVE" "$URL"

rm -rf "$OUTPUT_DIR"
tar xzf "$ARCHIVE" -C "$PROJECT_DIR/ghostty/macos"
rm "$ARCHIVE"

if [ ! -d "$OUTPUT_DIR" ]; then
  echo "Error: $OUTPUT_DIR not found after extraction" >&2
  exit 1
fi

echo "==> GhosttyKit.xcframework ready"
