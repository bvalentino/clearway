#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) git binary from source for bundling
# inside Clearway.app/Contents/Resources/git.
#
# Usage: ./scripts/bundle-git.sh [git-version]
#   e.g. ./scripts/bundle-git.sh 2.47.1
#
# Prerequisites: Xcode (or Command Line Tools) — provides the compiler,
# system curl, and system zlib that git links against.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GIT_VERSION="${1:-2.47.1}"
GIT_TARBALL="git-${GIT_VERSION}.tar.xz"
GIT_URL="https://mirrors.edge.kernel.org/pub/software/scm/git/${GIT_TARBALL}"
BUILD_DIR="$(mktemp -d)"
OUTPUT="$PROJECT_DIR/Resources/git"

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

echo "==> Downloading git ${GIT_VERSION}..."
curl --fail --show-error --location \
  --retry 3 --retry-delay 5 --retry-all-errors \
  -o "$BUILD_DIR/$GIT_TARBALL" "$GIT_URL"

echo "==> Extracting..."
tar xf "$BUILD_DIR/$GIT_TARBALL" -C "$BUILD_DIR"
SRC_DIR="$BUILD_DIR/git-${GIT_VERSION}"

build_arch() {
  local arch="$1"
  local prefix="$BUILD_DIR/install-${arch}"
  echo "==> Building git for ${arch}..."
  make -C "$SRC_DIR" clean >/dev/null 2>&1 || true
  make -C "$SRC_DIR" -j"$(sysctl -n hw.ncpu)" \
    prefix="$prefix" \
    CFLAGS="-Os -arch ${arch} -mmacosx-version-min=13.0" \
    LDFLAGS="-arch ${arch} -mmacosx-version-min=13.0" \
    NO_GETTEXT=1 \
    NO_OPENSSL=1 \
    NO_TCLTK=1 \
    NO_PERL=1 \
    NO_PYTHON=1 \
    NO_EXPAT=1 \
    NO_INSTALL_HARDLINKS=1 \
    all >/dev/null 2>&1
  cp "$SRC_DIR/git" "$BUILD_DIR/git-${arch}"
}

build_arch arm64
build_arch x86_64

echo "==> Creating universal binary..."
lipo -create "$BUILD_DIR/git-arm64" "$BUILD_DIR/git-x86_64" -output "$OUTPUT"
strip "$OUTPUT"
chmod +x "$OUTPUT"

echo "==> Verifying..."
lipo -info "$OUTPUT"
SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "==> Resources/git ready (${SIZE})"
