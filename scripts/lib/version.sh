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

# Interactively prompt for a new MARKETING_VERSION, showing the current value.
# If the user enters a new value, update project.yml in-place and refresh the
# exported variables. Empty input keeps the current value unchanged. Skipped
# in non-interactive runs (stdin not a tty) so CI invocations still work.
clearway_prompt_marketing_version() {
  local project_yml="${CLEARWAY_PROJECT_DIR:-$PROJECT_DIR}/project.yml"
  clearway_read_versions
  local current="$MARKETING_VERSION"

  if [ ! -t 0 ]; then
    echo "==> Non-interactive run; keeping MARKETING_VERSION=$current"
    return 0
  fi

  printf "Current MARKETING_VERSION: %s\n" "$current"
  printf "New MARKETING_VERSION (empty to keep %s): " "$current"
  local new_version
  read -r new_version

  if [ -z "$new_version" ] || [ "$new_version" = "$current" ]; then
    echo "==> Keeping MARKETING_VERSION=$current"
    return 0
  fi

  if ! [[ "$new_version" =~ ^[0-9]+(\.[0-9]+)*([.+-][A-Za-z0-9.+-]+)?$ ]]; then
    echo "Error: '$new_version' does not look like a version string (e.g., 1.0.1, 2.0, 1.0.0-beta)." >&2
    return 1
  fi

  sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*\")[^\"]+(\")/\1${new_version}\2/" "$project_yml"
  clearway_read_versions
  echo "==> bumped MARKETING_VERSION: $current → $MARKETING_VERSION"
}
