#!/bin/bash
set -e

PRIMARY_WORKTREE="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"

# Copy submodule source files (without linking back to shared git module state,
# which only supports one worktree at a time and causes conflicts)
rm -rf ghostty wtpad-cli
cp -r "$PRIMARY_WORKTREE/ghostty" .
cp -r "$PRIMARY_WORKTREE/wtpad-cli" .
rm -f ghostty/.git wtpad-cli/.git

# Ensure BuildInfo.generated.swift exists so xcodegen includes it
BUILDINFO="Sources/App/BuildInfo.generated.swift"
if [ ! -f "$BUILDINFO" ]; then
  cat > "$BUILDINFO" <<'SWIFT'
// Auto-generated at build time — do not edit.
enum BuildInfo {
    static let commit = "unknown"
    static let wtpadVersion = "unknown"
}
SWIFT
fi
