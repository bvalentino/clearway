#!/usr/bin/env bash
# Release stage 3: publish the notarized DMG from package.sh.
#
# Verifies the DMG, signs it with Sparkle's EdDSA key, prepares the appcast
# entry and the release notes, then asks once. On y it pushes the release
# commit, creates the GitHub release with both DMGs, and commits and pushes
# docs/appcast.xml — in that order, so the appcast never advertises a DMG that
# is not downloadable yet.
#
# Run through ./scripts/release.sh; run directly only to resume a release.
#
# Release notes are never hand-written. The script asks GitHub for the notes
# it would auto-generate for the tag (merged PR titles since the previous
# release), saves them to release/<tag>-notes.md for the GitHub release, and
# embeds a trimmed Markdown copy (no author/PR suffixes, no "Full Changelog"
# footer) in the appcast <description> so Sparkle's update dialog shows the
# list of changes inline.
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ ! -t 0 ]; then
  echo "Error: publish.sh asks for confirmation before publishing; run it in a terminal."
  exit 1
fi

clearway_read_versions
clearway_require_publish_env
clearway_read_repo_slug

TAG="v${MARKETING_VERSION}"
clearway_require_tag_free "$TAG"

clearway_require_main_branch
clearway_require_clean_tree
git fetch --quiet origin main
if ! git merge-base --is-ancestor origin/main HEAD; then
  echo "Error: origin/main has commits this checkout lacks, so the release commit cannot be pushed."
  exit 1
fi

# The tag is created at HEAD, and the DMG is named after the commit it was built
# from, so a DMG that exists under HEAD's name is the build of the tagged commit.
RELEASE_COMMIT=$(git rev-parse HEAD)
DMG_PATH="$RELEASE_DIR/$(clearway_artifact_base).dmg"
DMG_BASENAME=$(basename "$DMG_PATH")

if [ ! -f "$DMG_PATH" ]; then
  echo "Error: $DMG_PATH not found. Run ./scripts/release/package.sh first."
  exit 1
fi

APPCAST_PATH="$PROJECT_DIR/docs/appcast.xml"
if [ ! -f "$APPCAST_PATH" ]; then
  echo "Error: $APPCAST_PATH not found."
  exit 1
fi

# sign_update ships in Sparkle's SPM artifact bundle under this project's
# DerivedData; the Release build in build.sh resolves the package.
BUILD_DIR=$(xcodebuild -project Clearway.xcodeproj -scheme Clearway \
  -configuration Release -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | grep -m1 '^\s*BUILD_DIR' | awk '{print $3}')
DERIVED_ROOT="${BUILD_DIR%/Build/Products}"
SIGN_UPDATE="$DERIVED_ROOT/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"

if [ ! -x "$SIGN_UPDATE" ]; then
  echo "Error: sign_update not found at $SIGN_UPDATE"
  echo "       Run ./scripts/release/build.sh first so Xcode resolves the Sparkle SPM package."
  exit 1
fi

MOUNT_POINT=""
NEW_ITEM_FILE=$(mktemp)
NEW_APPCAST_FILE=$(mktemp)
cleanup() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || \
      hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
  fi
  rm -f "$NEW_ITEM_FILE" "$NEW_APPCAST_FILE"
}
trap cleanup EXIT

# --- Notarization / Gatekeeper guardrail --------------------------------------
# Publishing an un-stapled DMG would mean the appcast advertises an EdDSA-valid
# but Gatekeeper-rejected update.
echo "==> Validating $DMG_BASENAME is stapled and notarized..."
if ! xcrun stapler validate "$DMG_PATH" >/dev/null 2>&1; then
  echo "Error: $DMG_PATH is not stapled. Re-run ./scripts/release/package.sh."
  exit 1
fi
if ! spctl -a -t open --context context:primary-signature "$DMG_PATH" >/dev/null 2>&1; then
  echo "Error: Gatekeeper rejected $DMG_PATH."
  echo "       spctl output (for diagnosis):"
  spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true
  exit 1
fi

# --- Version guardrail ---------------------------------------------------------
echo "==> Mounting $DMG_BASENAME (read-only) to check build number..."
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
# is Gatekeeper-acceptable. The app carries no stapled ticket of its own (the
# DMG submission notarizes it as nested content), so this check needs network.
if ! spctl -a -t exec "$APP_IN_DMG" >/dev/null 2>&1; then
  echo "Error: Gatekeeper rejected $(basename "$APP_IN_DMG") inside the DMG."
  echo "       spctl output (for diagnosis):"
  spctl -a -t exec -vv "$APP_IN_DMG" || true
  exit 1
fi

DMG_BUILD=$(plutil -extract CFBundleVersion raw -o - "$APP_IN_DMG/Contents/Info.plist")

hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

if [ "$DMG_BUILD" != "$CURRENT_PROJECT_VERSION" ]; then
  echo "Error: DMG build number $DMG_BUILD does not match project.yml build number $CURRENT_PROJECT_VERSION."
  exit 1
fi

# --- Sign the DMG --------------------------------------------------------------
BYTES=$(stat -f %z "$DMG_PATH")

echo "==> Signing $DMG_BASENAME with Sparkle EdDSA key..."
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
RELEASE_PAGE_URL="https://github.com/${REPO_SLUG}/releases/tag/${TAG}"
CHANGES=$(printf '%s\n' "$GITHUB_NOTES" \
  | sed -E '/^## What.s Changed$/d; /^\*\*Full Changelog\*\*/d; s/ by @[^ ]+ in https?:[^ ]+$//' \
  | cat -s \
  | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}')
UPDATE_NOTES="${CHANGES}

[${TAG} on GitHub](${RELEASE_PAGE_URL})"
UPDATE_NOTES=${UPDATE_NOTES//]]>/]]]]><![CDATA[>}

# --- Prepare the appcast -------------------------------------------------------
PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/${REPO_SLUG}/releases/download/${TAG}/${DMG_BASENAME}"

cat >"$NEW_ITEM_FILE" <<EOF
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

# Insert before the first existing <item> so the feed stays newest-first, or
# before </channel> when there is none. BSD awk does not allow literal newlines
# in -v values, so the item is streamed in from a file. The result stays in a
# temp file until the GitHub release exists.
awk -v item_file="$NEW_ITEM_FILE" '
  function emit_item(   line) {
    while ((getline line < item_file) > 0) print line
    close(item_file)
    inserted = 1
  }
  BEGIN { inserted = 0 }
  !inserted && /<item>/ { emit_item() }
  !inserted && /<\/channel>/ { emit_item() }
  { print }
' "$APPCAST_PATH" >"$NEW_APPCAST_FILE"

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$NEW_APPCAST_FILE"
else
  python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$NEW_APPCAST_FILE"
fi

# The landing page on getclearway.com links directly to
#   https://github.com/<slug>/releases/latest/download/Clearway.dmg
# which requires a release asset named exactly "Clearway.dmg". Sparkle's
# appcast <enclosure url> keeps pointing at the versioned filename, so BOTH
# files ship as assets of every release. Same bytes → same EdDSA signature.
LATEST_DMG="$RELEASE_DIR/Clearway.dmg"
cp "$DMG_PATH" "$LATEST_DMG"

# --- Confirm -------------------------------------------------------------------
echo ""
echo "==> Ready to publish"
echo "    Version: ${MARKETING_VERSION} (build ${CURRENT_PROJECT_VERSION})"
echo "    Commit:  $(git log -1 --format='%h %s' "$RELEASE_COMMIT")"
echo "    DMG:     $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"
echo "    Changes${PREVIOUS_TAG:+ since $PREVIOUS_TAG}:"
printf '%s\n' "$CHANGES" | sed 's/^/      /'
echo ""
echo "This pushes main, creates the public GitHub release ${TAG} on ${REPO_SLUG}"
echo "and updates the Sparkle appcast. It cannot be undone from here."
printf "Publish %s? [y/N] " "$TAG"
read -r ANSWER
if [ "$ANSWER" != "y" ] && [ "$ANSWER" != "Y" ]; then
  echo "Not published. Nothing was pushed."
  exit 1
fi

# --- Publish -------------------------------------------------------------------
echo "==> Pushing $(git rev-parse --short "$RELEASE_COMMIT") to origin/main..."
git push origin "${RELEASE_COMMIT}:refs/heads/main"

echo "==> Creating GitHub release ${TAG}..."
gh release create "$TAG" "$DMG_PATH" "$LATEST_DMG" \
  --repo "$REPO_SLUG" \
  --target "$RELEASE_COMMIT" \
  --title "$TAG" \
  --notes-file "$NOTES_FILE"

echo "==> Publishing the appcast..."
cp "$NEW_APPCAST_FILE" "$APPCAST_PATH"
git add docs/appcast.xml
git commit --quiet -m "Publish ${TAG} appcast"
git push origin HEAD:refs/heads/main

echo ""
echo "==> Published ${TAG}"
echo "    ${RELEASE_PAGE_URL}"
