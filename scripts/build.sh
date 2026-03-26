#!/usr/bin/env bash
# Build Clearway in Debug configuration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Derive product name from worktree directory.
# Main worktree → "Clearway"; others → "Clearway (worktree-name)"
WORKTREE_DIR="$(basename "$PROJECT_DIR")"
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree &>/dev/null \
   && [ "$(git -C "$PROJECT_DIR" worktree list --porcelain | head -1 | awk '{print $2}')" != "$PROJECT_DIR" ]; then
  PRODUCT_NAME="Clearway ($WORKTREE_DIR)"
else
  PRODUCT_NAME="Clearway"
fi

echo "==> Building $PRODUCT_NAME (Debug)..."
xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Debug -destination 'platform=macOS' \
  PRODUCT_NAME="$PRODUCT_NAME" PRODUCT_MODULE_NAME=Clearway build -quiet

echo "==> Build succeeded."
