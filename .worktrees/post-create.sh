#!/bin/bash
set -e

PRIMARY_WORKTREE="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"

# Copy ghostty submodule
rm -rf ghostty
cp -r "$PRIMARY_WORKTREE/ghostty" .
echo "gitdir: $PRIMARY_WORKTREE/.git/modules/ghostty" > ghostty/.git

# Copy wtpad-cli submodule
rm -rf wtpad-cli
cp -r "$PRIMARY_WORKTREE/wtpad-cli" .
echo "gitdir: $PRIMARY_WORKTREE/.git/modules/wtpad-cli" > wtpad-cli/.git

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
