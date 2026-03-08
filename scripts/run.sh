#!/usr/bin/env bash
# Launch the most recent Debug build of wtpad.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Resolve the exact DerivedData path for this project directory.
# xcodebuild hashes the project path, so each worktree gets its own directory.
APP_PATH=$(xcodebuild -project wtpad.xcodeproj -scheme wtpad -configuration Debug -showBuildSettings 2>/dev/null \
    | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')

if [[ -z "$APP_PATH" || ! -d "$APP_PATH/wtpad.app" ]]; then
    echo "Error: could not locate wtpad.app in DerivedData"
    echo "Run ./scripts/build.sh first."
    exit 1
fi

echo "==> Launching $APP_PATH/wtpad.app"
open "$APP_PATH/wtpad.app"
