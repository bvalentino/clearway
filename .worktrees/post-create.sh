#!/bin/bash
set -e

PRIMARY_WORKTREE="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
echo "The primary worktree path: $PRIMARY_WORKTREE"

# Copy submodule source files (without linking back to shared git module state,
# which only supports one worktree at a time and causes conflicts)
echo "Setting up ghostty submodule"
rm -rf ghostty
cp -r "$PRIMARY_WORKTREE/ghostty" .
rm -f ghostty/.git

# Symlink local config files so worktrees share settings with primary
echo "Symlinking files from primary"
ln -sf "$PRIMARY_WORKTREE/.claude/settings.local.json" .claude/settings.local.json

# Ensure BuildInfo.generated.swift exists so xcodegen includes it
echo "Ensuring BuildInfo.generated.swift exists for xcodegen"
BUILDINFO="Sources/App/BuildInfo.generated.swift"
if [ ! -f "$BUILDINFO" ]; then
  cat > "$BUILDINFO" <<'SWIFT'
// Auto-generated at build time — do not edit.
enum BuildInfo {
    static let commit = "unknown"
}
SWIFT
fi

echo "🎉 Done! The worktree is ready"
