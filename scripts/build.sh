#!/usr/bin/env bash
# Build wtpad in Debug configuration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Derive product name from worktree directory.
# Main worktree → "wtpad"; others → "wtpad (worktree-name)"
WORKTREE_DIR="$(basename "$PROJECT_DIR")"
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree &>/dev/null \
   && [ "$(git -C "$PROJECT_DIR" worktree list --porcelain | head -1 | awk '{print $2}')" != "$PROJECT_DIR" ]; then
  PRODUCT_NAME="wtpad ($WORKTREE_DIR)"
else
  PRODUCT_NAME="wtpad"
fi

echo "==> Building $PRODUCT_NAME (Debug)..."
xcodebuild -project wtpad.xcodeproj -scheme wtpad -configuration Debug -destination 'platform=macOS' \
  PRODUCT_NAME="$PRODUCT_NAME" PRODUCT_MODULE_NAME=wtpad build -quiet

echo "==> Build succeeded."
