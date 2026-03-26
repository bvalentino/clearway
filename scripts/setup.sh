#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> Initializing submodules..."
git submodule update --init --recursive

echo "==> Checking for zig..."
if ! command -v zig &> /dev/null; then
    echo "Error: zig is not installed."
    echo "Install via: brew install zig"
    exit 1
fi

echo "==> Ensuring Metal Toolchain is installed..."
if ! xcrun metal --version &> /dev/null; then
    echo "    Metal Toolchain not found, downloading..."
    xcodebuild -downloadComponent MetalToolchain
fi

echo "==> Building GhosttyKit.xcframework (this may take a few minutes)..."
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
cd ..

echo "==> Checking for xcodegen..."
if ! command -v xcodegen &> /dev/null; then
    echo "Error: xcodegen is not installed."
    echo "Install via: brew install xcodegen"
    exit 1
fi

echo "==> Creating BuildInfo placeholder..."
BUILDINFO="$PROJECT_DIR/Sources/App/BuildInfo.generated.swift"
if [ ! -f "$BUILDINFO" ]; then
    cat > "$BUILDINFO" <<'SWIFT'
// Auto-generated at build time — do not edit.
enum BuildInfo {
    static let commit = "unknown"
}
SWIFT
fi

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Setup complete!"
echo ""
echo "Open Clearway.xcodeproj in Xcode, or build from the command line:"
echo "  xcodebuild -project Clearway.xcodeproj -scheme Clearway -configuration Debug build"
