#!/usr/bin/env bash
# Launch the most recent Debug build of wtpad.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Derive product name from worktree directory (must match build.sh logic).
WORKTREE_DIR="$(basename "$PROJECT_DIR")"
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree &>/dev/null \
   && [ "$(git -C "$PROJECT_DIR" worktree list --porcelain | head -1 | awk '{print $2}')" != "$PROJECT_DIR" ]; then
  PRODUCT_NAME="wtpad ($WORKTREE_DIR)"
else
  PRODUCT_NAME="wtpad"
fi

# Resolve the exact DerivedData path for this project directory.
# xcodebuild hashes the project path, so each worktree gets its own directory.
APP_PATH=$(xcodebuild -project wtpad.xcodeproj -scheme wtpad -configuration Debug -showBuildSettings 2>/dev/null \
    | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')

if [[ -z "$APP_PATH" || ! -d "$APP_PATH/$PRODUCT_NAME.app" ]]; then
    echo "Error: could not locate $PRODUCT_NAME.app in DerivedData"
    echo "Run ./scripts/build.sh first."
    exit 1
fi

echo "==> Launching $APP_PATH/$PRODUCT_NAME.app"
open "$APP_PATH/$PRODUCT_NAME.app"
