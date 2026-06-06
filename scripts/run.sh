#!/usr/bin/env bash
# Launch the most recent Debug build of Clearway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Derive product name from worktree directory (must match build.sh logic).
WORKTREE_DIR="$(basename "$PROJECT_DIR")"
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree &>/dev/null \
   && [ "$(git -C "$PROJECT_DIR" worktree list --porcelain | head -1 | awk '{print $2}')" != "$PROJECT_DIR" ]; then
  PRODUCT_NAME="Clearway ($WORKTREE_DIR)"
else
  PRODUCT_NAME="Clearway"
fi

# Resolve the exact DerivedData path for this project directory.
# xcodebuild hashes the project path, so each worktree gets its own directory.
APP_PATH=$(xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Debug -showBuildSettings 2>/dev/null \
    | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p')

# Collect the candidate bundles that exist: the worktree-suffixed name that
# build.sh produces, plus the default "Clearway.app" from an Xcode GUI or plain
# `xcodebuild` build (which ignore build.sh's PRODUCT_NAME override). When both
# exist, launch whichever was built most recently.
candidates=()
if [[ -n "$APP_PATH" ]]; then
    [[ -d "$APP_PATH/$PRODUCT_NAME.app" ]] && candidates+=("$APP_PATH/$PRODUCT_NAME.app")
    if [[ "$PRODUCT_NAME" != "Clearway" && -d "$APP_PATH/Clearway.app" ]]; then
        candidates+=("$APP_PATH/Clearway.app")
    fi
fi

if [[ ${#candidates[@]} -eq 0 ]]; then
    if [[ "$PRODUCT_NAME" == "Clearway" ]]; then
        echo "Error: could not locate Clearway.app in DerivedData"
    else
        echo "Error: could not locate $PRODUCT_NAME.app (or Clearway.app) in DerivedData"
    fi
    echo "Run ./scripts/build.sh first."
    exit 1
fi

# Newest build wins (the .app directory mtime is bumped on each build).
APP="${candidates[0]}"
if [[ ${#candidates[@]} -gt 1 && "${candidates[1]}" -nt "$APP" ]]; then
    APP="${candidates[1]}"
fi

echo "==> Launching $APP"
open "$APP"
