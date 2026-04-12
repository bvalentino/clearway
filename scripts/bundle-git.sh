#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) git runtime from source for bundling
# inside Clearway.app/Contents/Resources/git-dist/.
#
# Produces:
#   Resources/git-dist/git              — universal main binary
#   Resources/git-dist/git-core/        — transport helpers (GIT_EXEC_PATH target)
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
OUTPUT_DIR="$PROJECT_DIR/Resources/git-dist"

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

echo "==> Downloading git ${GIT_VERSION}..."
curl --fail --show-error --location \
  --retry 3 --retry-delay 5 --retry-all-errors \
  -o "$BUILD_DIR/$GIT_TARBALL" "$GIT_URL"

echo "==> Extracting..."
tar xf "$BUILD_DIR/$GIT_TARBALL" -C "$BUILD_DIR"
SRC_DIR="$BUILD_DIR/git-${GIT_VERSION}"

MAKE_FLAGS=(
  NO_GETTEXT=1
  NO_OPENSSL=1
  NO_TCLTK=1
  NO_PERL=1
  NO_PYTHON=1
  NO_EXPAT=1
  NO_INSTALL_HARDLINKS=1
)

build_arch() {
  local arch="$1"
  local prefix="$BUILD_DIR/install-${arch}"
  echo "==> Building + installing git for ${arch}..."
  make -C "$SRC_DIR" clean >/dev/null 2>&1 || true
  make -C "$SRC_DIR" -j"$(sysctl -n hw.ncpu)" \
    prefix="$prefix" \
    CFLAGS="-Os -arch ${arch} -mmacosx-version-min=13.0" \
    LDFLAGS="-arch ${arch} -mmacosx-version-min=13.0" \
    "${MAKE_FLAGS[@]}" \
    all >/dev/null 2>&1
  make -C "$SRC_DIR" \
    prefix="$prefix" \
    CFLAGS="-Os -arch ${arch} -mmacosx-version-min=13.0" \
    LDFLAGS="-arch ${arch} -mmacosx-version-min=13.0" \
    "${MAKE_FLAGS[@]}" \
    install >/dev/null 2>&1
}

build_arch arm64
build_arch x86_64

echo "==> Creating universal binaries..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/git-core"

# Main git binary
lipo -create \
  "$BUILD_DIR/install-arm64/bin/git" \
  "$BUILD_DIR/install-x86_64/bin/git" \
  -output "$OUTPUT_DIR/git"
strip "$OUTPUT_DIR/git"
chmod +x "$OUTPUT_DIR/git"

# Identify distinct helper binaries in git-core (not hardlinks to git).
# Built-in commands are hardlinked to the main git binary — we skip those
# since git dispatches them internally. We only need the separate executables
# (transport helpers like git-remote-https).
ARM_GIT_INODE=$(stat -f %i "$BUILD_DIR/install-arm64/bin/git")
HELPER_COUNT=0

for arm_file in "$BUILD_DIR/install-arm64/libexec/git-core/"*; do
  [ -f "$arm_file" ] || continue
  name=$(basename "$arm_file")

  file_inode=$(stat -f %i "$arm_file")
  if [ "$file_inode" = "$ARM_GIT_INODE" ]; then
    # Built-in command hardlinked to git — skip, handled by git internally
    continue
  fi

  # Check if the x86_64 counterpart exists (it should for real helpers)
  x86_file="$BUILD_DIR/install-x86_64/libexec/git-core/$name"
  if [ ! -f "$x86_file" ]; then
    echo "    skipping $name (no x86_64 counterpart)"
    continue
  fi

  # Check if it's a Mach-O binary (skip shell scripts)
  if ! file "$arm_file" | grep -q "Mach-O"; then
    continue
  fi

  echo "    lipo $name"
  lipo -create "$arm_file" "$x86_file" -output "$OUTPUT_DIR/git-core/$name"
  strip "$OUTPUT_DIR/git-core/$name"
  chmod +x "$OUTPUT_DIR/git-core/$name"
  HELPER_COUNT=$((HELPER_COUNT + 1))
done

echo "==> Verifying..."
lipo -info "$OUTPUT_DIR/git"
MAIN_SIZE=$(du -h "$OUTPUT_DIR/git" | cut -f1)
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
echo "==> git-dist ready: main binary ${MAIN_SIZE}, total ${TOTAL_SIZE} (${HELPER_COUNT} helpers)"

# Sanity check: git-remote-https must be present for fetch/push to work
if [ ! -x "$OUTPUT_DIR/git-core/git-remote-https" ]; then
  echo "error: git-remote-https not found in git-core — remote operations will fail" >&2
  exit 1
fi
