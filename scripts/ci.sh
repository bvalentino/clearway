#!/usr/bin/env bash
# Run the full local gate: lint, build, and test. Mirrors .github/workflows/ci.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Regenerating Xcode project..."
xcodegen generate --quiet

echo "==> Linting..."
swiftlint lint --quiet

echo "==> Building and testing..."
# No PRODUCT_NAME override here: it renames the app bundle out from under TEST_HOST.
if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild -project Clearway.xcodeproj -scheme ClearwayTests -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" test | xcbeautify --quiet --disable-logging
else
  xcodebuild -project Clearway.xcodeproj -scheme ClearwayTests -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" test -quiet
fi

echo "==> CI passed."
