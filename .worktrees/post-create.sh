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
