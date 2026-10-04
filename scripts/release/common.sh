# scripts/release/common.sh — paths, version handling and preflight checks shared
# by scripts/release.sh and the stages beside this file. Source it; it changes
# directory to the repo root and defines functions, nothing else.
# shellcheck shell=bash disable=SC2034

RELEASE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$RELEASE_SCRIPTS_DIR/../.." && pwd)"
RELEASE_DIR="$PROJECT_DIR/release"
PRODUCT_NAME="Clearway"

cd "$PROJECT_DIR" || return

clearway_read_versions() {
  MARKETING_VERSION=$(grep 'MARKETING_VERSION' "$PROJECT_DIR/project.yml" | head -1 | awk -F'"' '{print $2}')
  CURRENT_PROJECT_VERSION=$(grep 'CURRENT_PROJECT_VERSION' "$PROJECT_DIR/project.yml" | head -1 | awk '{print $2}')
  export MARKETING_VERSION CURRENT_PROJECT_VERSION
}

clearway_bump_build_number() {
  clearway_read_versions
  local next=$((CURRENT_PROJECT_VERSION + 1))
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:)[[:space:]]*[0-9]+$/\1 ${next}/" "$PROJECT_DIR/project.yml"
  clearway_read_versions
  echo "==> bumped CURRENT_PROJECT_VERSION → $CURRENT_PROJECT_VERSION"
}

# Sets NEW_MARKETING_VERSION without touching project.yml, so the caller can
# reject the answer while the tree is still clean.
clearway_prompt_marketing_version() {
  clearway_read_versions
  printf "Current MARKETING_VERSION: %s\n" "$MARKETING_VERSION"
  printf "New MARKETING_VERSION: "
  read -r NEW_MARKETING_VERSION

  if ! [[ "$NEW_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+)*([.+-][A-Za-z0-9.+-]+)?$ ]]; then
    echo "Error: '$NEW_MARKETING_VERSION' does not look like a version string (e.g., 1.0.1, 2.0, 1.0.0-beta)." >&2
    return 1
  fi
}

clearway_set_marketing_version() {
  local previous="$MARKETING_VERSION"
  sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*\")[^\"]+(\")/\1$1\2/" "$PROJECT_DIR/project.yml"
  clearway_read_versions
  echo "==> bumped MARKETING_VERSION: $previous → $MARKETING_VERSION"
}

# Names every artifact of a release after the commit it was built from, so each
# stage finds the previous stage's output without guessing at "newest file".
clearway_artifact_base() {
  echo "${PRODUCT_NAME}-${MARKETING_VERSION}-$(git rev-parse --short HEAD)"
}

clearway_require_main_branch() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$branch" != "main" ]; then
    echo "Error: releases are cut from main; currently on '$branch'." >&2
    return 1
  fi
}

# Untracked files are ignored: a Debug launch leaves default.profraw behind.
clearway_require_clean_tree() {
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Error: the working tree has uncommitted changes to tracked files:" >&2
    git status --short --untracked-files=no >&2
    return 1
  fi
}

clearway_require_notary_env() {
  : "${ASC_API_KEY_PATH:?Set ASC_API_KEY_PATH to your App Store Connect API .p8 file path}"
  : "${ASC_API_KEY_ID:?Set ASC_API_KEY_ID to your App Store Connect API Key ID}"
  : "${ASC_API_ISSUER_ID:?Set ASC_API_ISSUER_ID to your App Store Connect Issuer ID}"
  if [ ! -f "$ASC_API_KEY_PATH" ]; then
    echo "Error: ASC_API_KEY_PATH points to a file that doesn't exist: $ASC_API_KEY_PATH" >&2
    return 1
  fi
}

clearway_require_publish_env() {
  : "${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH to the path of your exported Sparkle private key (see RELEASING.md in the repo root)}"
  if [ ! -r "$SPARKLE_PRIVATE_KEY_PATH" ]; then
    echo "Error: SPARKLE_PRIVATE_KEY_PATH is not a readable file: $SPARKLE_PRIVATE_KEY_PATH" >&2
    return 1
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh is required to generate release notes and create the release." >&2
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: gh is not logged in. Run 'gh auth login'." >&2
    return 1
  fi
}

clearway_read_repo_slug() {
  REPO_SLUG=$(git remote get-url origin | sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##')
  if [ -z "$REPO_SLUG" ] || [[ "$REPO_SLUG" != */* ]]; then
    echo "Error: could not derive REPO_SLUG from 'git remote get-url origin'." >&2
    echo "       Got: $REPO_SLUG" >&2
    return 1
  fi
}

# Sparkle compares CFBundleVersion for update detection, but each public release
# needs a distinct MARKETING_VERSION so the GitHub tag, download URL and Sparkle
# UI version label stay unique. Requires REPO_SLUG.
clearway_require_tag_free() {
  local tag="$1" where=""
  if git rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null 2>&1; then
    where="local"
  elif gh release view "${tag}" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    where="remote"
  fi
  if [ -n "$where" ]; then
    echo "Error: release tag ${tag} already exists ($where). Pick a new MARKETING_VERSION." >&2
    return 1
  fi
}
