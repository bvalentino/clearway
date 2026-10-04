#!/usr/bin/env bash
# Cut a Clearway release end to end:
#
#   preflight → version bump + "Release v<version>" commit
#             → release/build.sh    clean Release build, zipped
#             → release/package.sh  DMG, signed, notarized, stapled
#             → release/publish.sh  asks once, then pushes main, creates the
#                                   GitHub release and publishes the appcast
#
# Nothing leaves this machine until publish.sh's prompt is answered with y.
# See RELEASING.md for setup and for resuming after a failed stage.
set -euo pipefail

# shellcheck source=release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release/common.sh"

if [ ! -t 0 ]; then
  echo "Error: release.sh prompts for the version and for the publish confirmation; run it in a terminal."
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen is required. Run ./scripts/setup.sh."
  exit 1
fi

echo "==> Preflight..."
clearway_require_main_branch
clearway_require_clean_tree
git fetch --quiet origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Error: main is not in sync with origin/main."
  echo "       If an earlier release run stopped part-way, its release commit is"
  echo "       still local: resume with the stage that failed (see RELEASING.md)."
  exit 1
fi
clearway_require_notary_env
clearway_require_publish_env
clearway_read_repo_slug

clearway_prompt_marketing_version
clearway_require_tag_free "v${NEW_MARKETING_VERSION}"
clearway_set_marketing_version "$NEW_MARKETING_VERSION"
clearway_bump_build_number
xcodegen generate

git add project.yml Clearway.xcodeproj/project.pbxproj
git commit --quiet -m "Release v${MARKETING_VERSION}"
echo "==> Committed Release v${MARKETING_VERSION} ($(git rev-parse --short HEAD)), not pushed yet"

STAGES=(build package publish)
for i in "${!STAGES[@]}"; do
  if ! "$RELEASE_SCRIPTS_DIR/${STAGES[$i]}.sh"; then
    echo ""
    echo "!!! ${STAGES[$i]} did not finish. Nothing was rolled back; the release commit is"
    echo "!!! $(git rev-parse --short HEAD). Once the cause is fixed, resume with:"
    for stage in "${STAGES[@]:$i}"; do
      echo "      ./scripts/release/$stage.sh"
    done
    exit 1
  fi
done
