#!/usr/bin/env bash
# Publish a Clearway update: sign the stapled DMG with Sparkle's EdDSA private
# key, inject a new <item> into docs/appcast.xml, validate the XML, and print
# the exact `gh release create` command for the user to run manually.
#
# Usage:
#   ./scripts/publish-update.sh [path/to/Clearway-*.dmg]
#
# If no argument is given, uses the most recent Clearway-*.dmg in release/.
# Run ./scripts/release.sh → ./scripts/notarize.sh → ./scripts/package-dmg.sh
# first to produce the stapled input.
#
# Required environment:
#   SPARKLE_PRIVATE_KEY_PATH  absolute path to the exported Sparkle ed25519
#                             private key (see RELEASING.md in the repo root)
#
# Release notes are never hand-written. The script asks GitHub for the notes
# it would auto-generate for the tag (merged PR titles since the previous
# release), saves them to release/<tag>-notes.md for `gh release create
# --notes-file`, and embeds a trimmed Markdown copy (no author/PR suffixes,
# no "Full Changelog" footer) in the appcast <description> so Sparkle's update
# dialog shows the list of changes inline.
#
# sign_update is resolved from Sparkle's SPM artifact bundle under this
# project's DerivedData — nothing needs to be installed on PATH. Run
# ./scripts/release.sh (which resolves the SPM package) at least once before
# running this script on a fresh checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"

cd "$PROJECT_DIR"

clearway_read_versions

: "${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH to the path of your exported Sparkle private key (see RELEASING.md in the repo root)}"

if [ ! -r "$SPARKLE_PRIVATE_KEY_PATH" ]; then
  echo "Error: SPARKLE_PRIVATE_KEY_PATH is not a readable file: $SPARKLE_PRIVATE_KEY_PATH"
  exit 1
fi

# Locate sign_update from Sparkle's SPM artifact bundle under this project's
# DerivedData. Xcode extracts the binary when it resolves the Sparkle package,
# so the first ./scripts/build.sh or ./scripts/release.sh run populates it.
# We reuse release.sh's BUILD_DIR trick and strip the /Build/Products suffix
# to get the DerivedData root.
BUILD_DIR=$(xcodebuild -project Clearway.xcodeproj -scheme Clearway \
  -configuration Release -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | grep -m1 '^\s*BUILD_DIR' | awk '{print $3}')
DERIVED_ROOT="${BUILD_DIR%/Build/Products}"
SIGN_UPDATE="$DERIVED_ROOT/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"

if [ ! -x "$SIGN_UPDATE" ]; then
  echo "Error: sign_update not found at $SIGN_UPDATE"
  echo "       Run ./scripts/release.sh first so Xcode resolves the Sparkle SPM package."
  exit 1
fi

# Resolve the DMG path: explicit argument, else newest Clearway-*.dmg in release/.
RELEASE_DIR="$PROJECT_DIR/release"
if [ $# -ge 1 ]; then
  DMG_PATH="$1"
else
  DMG_PATH=$(ls -t "$RELEASE_DIR"/Clearway-*.dmg 2>/dev/null | head -1 || true)
  if [ -z "$DMG_PATH" ]; then
    echo "Error: no Clearway-*.dmg in $RELEASE_DIR."
    echo "       Run ./scripts/package-dmg.sh first, or pass a dmg path as argument."
    exit 1
  fi
fi

if [ ! -f "$DMG_PATH" ]; then
  echo "Error: $DMG_PATH not found."
  exit 1
fi

# --- Notarization / Gatekeeper guardrail --------------------------------------
# package-dmg.sh notarizes, staples, and Gatekeeper-validates the DMG it
# produces, but this script may be invoked with an arbitrary path. Signing
# and publishing an un-stapled or pre-notarization DMG would mean the appcast
# advertises an EdDSA-valid but Gatekeeper-rejected update — so verify the
# DMG itself passes stapler + spctl before we touch anything else.
echo "==> Validating $(basename "$DMG_PATH") is stapled and notarized..."
if ! xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
  echo "Error: $DMG_PATH is not stapled."
  echo "       Only notarized+stapled DMGs should be published. Re-run"
  echo "       ./scripts/package-dmg.sh (which notarizes and staples) and"
  echo "       point this script at the resulting DMG."
  exit 1
fi
if ! spctl -a -t open --context context:primary-signature "$DMG_PATH" >/dev/null 2>&1; then
  echo "Error: Gatekeeper rejected $DMG_PATH."
  echo "       spctl output (for diagnosis):"
  spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true
  exit 1
fi

# --- Version guardrail ---------------------------------------------------------
# Mount the DMG read-only, read the bundled .app's CFBundleVersion, compare with
# project.yml's CURRENT_PROJECT_VERSION, and detach immediately via trap so a
# mid-script failure never leaves a stray mount behind.
MOUNT_POINT=""
cleanup_mount() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || \
      hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
  fi
}
trap cleanup_mount EXIT

echo "==> Mounting $(basename "$DMG_PATH") (read-only) to check build number..."
MOUNT_OUTPUT=$(hdiutil attach -readonly -nobrowse -noautoopen "$DMG_PATH")
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep -E '^/dev/' | tail -1 | awk '{for (i=3; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":""); print ""}')

if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
  echo "Error: failed to determine mount point for $DMG_PATH"
  exit 1
fi

APP_IN_DMG=$(find "$MOUNT_POINT" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "$APP_IN_DMG" ]; then
  echo "Error: no .app found inside $DMG_PATH"
  exit 1
fi

# Defense in depth: even if the outer DMG is stapled, confirm the inner .app
# is also stapled and Gatekeeper-acceptable. This catches the "stale DMG with
# same CFBundleVersion but unnotarized .app" class of operator error.
if ! xcrun stapler validate "$APP_IN_DMG" >/dev/null 2>&1; then
  echo "Error: $(basename "$APP_IN_DMG") inside the DMG is not stapled."
  echo "       Re-run ./scripts/notarize.sh → ./scripts/package-dmg.sh to produce"
  echo "       a notarized+stapled DMG before publishing."
  exit 1
fi
if ! spctl -a -t exec "$APP_IN_DMG" >/dev/null 2>&1; then
  echo "Error: Gatekeeper rejected $(basename "$APP_IN_DMG") inside the DMG."
  echo "       spctl output (for diagnosis):"
  spctl -a -t exec -vv "$APP_IN_DMG" || true
  exit 1
fi

DMG_BUILD=$(plutil -extract CFBundleVersion raw -o - "$APP_IN_DMG/Contents/Info.plist")

# Detach immediately so we don't hold the image open while signing.
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

if [ "$DMG_BUILD" != "$CURRENT_PROJECT_VERSION" ]; then
  echo "Error: DMG build number $DMG_BUILD does not match project.yml build number $CURRENT_PROJECT_VERSION."
  echo "       Rebuild by running ./scripts/release.sh (which bumps and rebuilds), then"
  echo "       ./scripts/notarize.sh, then ./scripts/package-dmg.sh."
  exit 1
fi

# --- Derive the GitHub slug from the origin remote ----------------------------
REPO_SLUG=$(git remote get-url origin | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')
if [ -z "$REPO_SLUG" ] || [[ "$REPO_SLUG" != */* ]]; then
  echo "Error: could not derive REPO_SLUG from 'git remote get-url origin'."
  echo "       Got: $REPO_SLUG"
  exit 1
fi

OWNER="${REPO_SLUG%%/*}"
REPO="${REPO_SLUG##*/}"
FEED_URL="https://${OWNER}.github.io/${REPO}/appcast.xml"

# --- Tag collision guardrail --------------------------------------------------
# The appcast <enclosure url> and the printed `gh release create` command both
# derive the tag from MARKETING_VERSION. If that tag already exists, publishing
# would either overwrite the old release or fail with "tag already exists" AND
# leave two <item> entries with identical <sparkle:shortVersionString>, which
# confuses Sparkle's "available update" UI. Bump MARKETING_VERSION in
# project.yml before publishing a new user-visible release.
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh is required to generate release notes and create the release."
  exit 1
fi

TAG="v${MARKETING_VERSION}"
TAG_EXISTS=""
if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null 2>&1; then
  TAG_EXISTS="local"
elif gh release view "${TAG}" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  TAG_EXISTS="remote"
fi

if [ -n "$TAG_EXISTS" ]; then
  echo "Error: release tag ${TAG} already exists ($TAG_EXISTS)."
  echo "       Bump MARKETING_VERSION in project.yml (then re-run release.sh"
  echo "       → notarize.sh → package-dmg.sh) before publishing a new release."
  echo "       Sparkle compares CFBundleVersion for update detection, but each"
  echo "       public release needs a distinct MARKETING_VERSION so the GitHub"
  echo "       tag, download URL, and Sparkle UI version label stay unique."
  exit 1
fi

# --- Sign the DMG --------------------------------------------------------------
BYTES=$(stat -f %z "$DMG_PATH")

echo "==> Signing $(basename "$DMG_PATH") with Sparkle EdDSA key..."
SIGN_OUTPUT=$("$SIGN_UPDATE" -f "$SPARKLE_PRIVATE_KEY_PATH" "$DMG_PATH")

SIG=$(echo "$SIGN_OUTPUT" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')
SIGN_LEN=$(echo "$SIGN_OUTPUT" | sed -nE 's/.*length="([^"]+)".*/\1/p')

if [ -z "$SIG" ] || [ "$SIG" = "$SIGN_OUTPUT" ]; then
  echo "Error: could not parse sparkle:edSignature from sign_update output."
  echo "       Raw output: $SIGN_OUTPUT"
  exit 1
fi

if [ -z "$SIGN_LEN" ] || [ "$SIGN_LEN" != "$BYTES" ]; then
  echo "Error: sign_update reported length=\"$SIGN_LEN\" but stat reported $BYTES."
  echo "       The DMG may have been modified between stat and sign_update; abort."
  exit 1
fi

# --- Compose the new <item> ----------------------------------------------------
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
DMG_BASENAME=$(basename "$DMG_PATH")
DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/v${MARKETING_VERSION}/${DMG_BASENAME}"
RELEASE_PAGE_URL="https://github.com/${REPO_SLUG}/releases/tag/${TAG}"

# --- Generate the release notes ------------------------------------------------
# Same text `gh release create --generate-notes` would write, fetched up front
# so the appcast and the GitHub release share it. previous_tag_name pins the
# range to the latest published release; without it GitHub picks the previous
# tag itself, which is only wrong on the very first release (no tags yet).
PREVIOUS_TAG=$(gh release view --repo "$REPO_SLUG" --json tagName --jq .tagName 2>/dev/null || true)
GENERATE_ARGS=(-f "tag_name=${TAG}")
if [ -n "$PREVIOUS_TAG" ]; then
  GENERATE_ARGS+=(-f "previous_tag_name=${PREVIOUS_TAG}")
fi

echo "==> Generating release notes for ${TAG}${PREVIOUS_TAG:+ since $PREVIOUS_TAG}..."
GITHUB_NOTES=$(gh api "repos/${REPO_SLUG}/releases/generate-notes" "${GENERATE_ARGS[@]}" --jq .body)
if [ -z "$GITHUB_NOTES" ]; then
  echo "Error: GitHub returned empty release notes for ${TAG}."
  exit 1
fi

NOTES_FILE="$RELEASE_DIR/${TAG}-notes.md"
printf '%s\n' "$GITHUB_NOTES" >"$NOTES_FILE"

# The update dialog gets the PR titles only: drop the section heading, the
# " by @author in <pr url>" suffix on each bullet, and the compare-link footer,
# then squeeze the blank lines that leaves behind and end with a link to the
# release page. Sparkle 2.9+ renders <description sparkle:format="markdown">.
UPDATE_NOTES=$(printf '%s\n' "$GITHUB_NOTES" \
  | sed -E '/^## What.s Changed$/d; /^\*\*Full Changelog\*\*/d; s/ by @[^ ]+ in https?:[^ ]+$//' \
  | cat -s \
  | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}')
UPDATE_NOTES="${UPDATE_NOTES}

[${TAG} on GitHub](${RELEASE_PAGE_URL})"
UPDATE_NOTES=${UPDATE_NOTES//]]>/]]]]><![CDATA[>}

# Build the new <item> block via heredoc so the template is readable. The block
# is then spliced into docs/appcast.xml below.
NEW_ITEM=$(cat <<EOF
    <item>
      <title>Version ${MARKETING_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${CURRENT_PROJECT_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
${UPDATE_NOTES}
      ]]></description>
      <enclosure url="${DOWNLOAD_URL}" length="${BYTES}" type="application/octet-stream" sparkle:edSignature="${SIG}"/>
    </item>
EOF
)

# --- Create appcast if missing -------------------------------------------------
APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml"
mkdir -p "$PROJECT_DIR/docs"

if [ ! -f "$APPCAST_PATH" ]; then
  echo "==> $APPCAST_PATH not found; writing empty skeleton."
  cat >"$APPCAST_PATH" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Clearway</title>
    <link>${FEED_URL}</link>
    <description>Most recent changes with links to updates.</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi

# --- Splice the new <item> into docs/appcast.xml ------------------------------
# Insertion policy: insert immediately before the first existing <item>, so
# newest-first ordering is preserved. If no <item> exists yet, insert just
# before </channel>. BSD awk on macOS does not allow literal newlines in -v
# variable values, so write NEW_ITEM to a temp file and stream it in via
# getline. The splice runs in a single awk pass.
NEW_ITEM_FILE=$(mktemp)
trap 'cleanup_mount; rm -f "$NEW_ITEM_FILE"' EXIT
printf '%s\n' "$NEW_ITEM" >"$NEW_ITEM_FILE"

UPDATED_APPCAST=$(awk -v item_file="$NEW_ITEM_FILE" '
  function emit_item(   line) {
    while ((getline line < item_file) > 0) print line
    close(item_file)
    inserted = 1
  }
  BEGIN { inserted = 0 }
  # Insert before the first <item> we see
  !inserted && /<item>/ { emit_item() }
  # Fallback: if we reach </channel> without seeing any <item>, insert here
  !inserted && /<\/channel>/ { emit_item() }
  { print }
' "$APPCAST_PATH")

printf '%s\n' "$UPDATED_APPCAST" >"$APPCAST_PATH"

# --- Validate the XML ---------------------------------------------------------
echo "==> Validating $APPCAST_PATH..."
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$APPCAST_PATH"
else
  python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$APPCAST_PATH"
fi

# --- Create the unversioned copy for the landing page's "latest" URL ---------
# The landing page on getclearway.com links directly to
#   https://github.com/<slug>/releases/latest/download/Clearway.dmg
# which requires a release asset named exactly "Clearway.dmg". Sparkle's
# appcast <enclosure url> keeps pointing at the versioned filename (which
# preserves historical identification on the release page), so we ship BOTH
# files as assets of every release. Same bytes → same EdDSA signature →
# both paths verify identically.
LATEST_DMG="$RELEASE_DIR/Clearway.dmg"
cp "$DMG_PATH" "$LATEST_DMG"
echo "==> Wrote unversioned copy for landing page: $LATEST_DMG"

# --- Print the manual follow-up commands --------------------------------------
echo ""
echo "==> Appcast updated: docs/appcast.xml"
echo ""
echo "Next steps (run manually):"
echo ""
echo "  1. Create the GitHub release with BOTH DMGs and the generated notes:"
echo "     gh release create ${TAG} \"$DMG_PATH\" \"$LATEST_DMG\" \\"
echo "       --repo \"$REPO_SLUG\" \\"
echo "       --title \"${TAG}\" \\"
echo "       --notes-file \"$NOTES_FILE\""
echo ""
echo "  2. Commit the version bump, regenerated pbxproj, and appcast so"
echo "     GitHub Pages redeploys docs/appcast.xml:"
echo "     git add project.yml Clearway.xcodeproj/project.pbxproj docs/appcast.xml"
echo "     git commit -m \"Release ${TAG}\" && git push"
