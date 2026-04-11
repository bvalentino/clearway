# scripts/lib/version.sh — shared version parsing/bumping for Clearway release scripts.
# Source from release.sh and publish-update.sh. Requires $PROJECT_DIR to be set
# to the repo root (caller's responsibility).
#
# Safe to source multiple times: only defines functions, no top-level side effects.
# Does not call `set -e` itself — caller's error handling is preserved. Every
# function returns a non-zero exit code on failure via `grep`/`sed` natural exit
# codes.

# Parse MARKETING_VERSION and CURRENT_PROJECT_VERSION from project.yml, then
# export both as environment variables for callers to consume.
clearway_read_versions() {
  local project_yml="${CLEARWAY_PROJECT_DIR:-$PROJECT_DIR}/project.yml"
  MARKETING_VERSION=$(grep 'MARKETING_VERSION' "$project_yml" | head -1 | awk -F'"' '{print $2}')
  CURRENT_PROJECT_VERSION=$(grep 'CURRENT_PROJECT_VERSION' "$project_yml" | head -1 | awk '{print $2}')
  export MARKETING_VERSION CURRENT_PROJECT_VERSION
}

# Increment CURRENT_PROJECT_VERSION by 1 in project.yml in-place (BSD sed).
# Refreshes the exported variables afterward and prints the new value.
clearway_bump_build_number() {
  local project_yml="${CLEARWAY_PROJECT_DIR:-$PROJECT_DIR}/project.yml"
  clearway_read_versions
  local next=$((CURRENT_PROJECT_VERSION + 1))
  sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:)[[:space:]]*[0-9]+$/\1 ${next}/" "$project_yml"
  clearway_read_versions
  echo "==> bumped CURRENT_PROJECT_VERSION → $CURRENT_PROJECT_VERSION"
}
