#!/usr/bin/env bash
# Build wtpad in Debug configuration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Building wtpad (Debug)..."
xcodebuild -project wtpad.xcodeproj -scheme wtpad -configuration Debug -destination 'platform=macOS' build -quiet

echo "==> Build succeeded."
