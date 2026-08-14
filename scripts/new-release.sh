#!/usr/bin/env bash
# Create and publish a Bear & Moose CA release.
#
# Flow: feature -> dev -> release/vX.Y.Z -> main, then main -> dev.
# conf/settings.cfg records the source-tree version and must match the annotated
# vX.Y.Z release tag. Each release also promotes the CHANGELOG.md Unreleased
# section to a dated release section. This script does not package or copy CA
# state, private keys, or other secrets.

set -Eeuo pipefail

readonly REMOTE="origin"
readonly MAIN_BRANCH="main"
readonly DEV_BRANCH="dev"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SETTINGS_FILE="$PROJECT_DIR/conf/settings.cfg"

CURRENT_BRANCH=""
PROJECT_NAME=""
NEW_VERSION=""
RELEASE_MESSAGE=""
NEXT_FEATURE_BRANCH=""
RELEASE_BRANCH=""
TAG_NAME=""

if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly BLUE=$'\033[0;34m'
    readonly NC=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

info()    { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
success() { printf '%s[SUCCESS]%s %s\n' "$GREEN" "$NC" "$*"; }
warn()    { printf '%s[WARNING]%s %s\n' "$YELLOW" "$NC" "$*"; }
error()   { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
die()     { error "$*"; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename -- "$0") <version> <release-message> <next-feature-branch>

Example:
  $(basename -- "$0") 0.1.0 "Bear & Moose CA 0.1.0" feat/backup-restore

The script must be run from a clean feat/* or feature/* branch. It fetches
$REMOTE, validates the release refs, asks for confirmation, performs the
release merges, updates conf/settings.cfg and CHANGELOG.md, and atomically
pushes main, dev, the release branch, and tag.
EOF
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ref_exists() {
    git show-ref --verify --quiet "$1"
}

validate_arguments() {
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }

    NEW_VERSION=$1
    RELEASE_MESSAGE=$2
    NEXT_FEATURE_BRANCH=$3
    RELEASE_BRANCH="release/v$NEW_VERSION"
    TAG_NAME="v$NEW_VERSION"

    [[ "$NEW_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?(\+[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
        die "Version must be a semantic version without a leading v (for example, 0.1.0)."
    [[ -n "$RELEASE_MESSAGE" ]] || die "Release message must not be empty."
    [[ "$NEXT_FEATURE_BRANCH" == feat/* || "$NEXT_FEATURE_BRANCH" == feature/* ]] ||
        die "Next feature branch must start with feat/ or feature/."

    git check-ref-format --branch "$RELEASE_BRANCH" >/dev/null ||
        die "Invalid release branch name: $RELEASE_BRANCH"
    git check-ref-format --branch "$NEXT_FEATURE_BRANCH" >/dev/null ||
        die "Invalid feature branch name: $NEXT_FEATURE_BRANCH"
}

preflight() {
    require_command git
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a Git repository."
    [[ "$(git rev-parse --show-toplevel)" == "$PROJECT_DIR" ]] ||
        die "Run this script from the bmca repository."
    git remote get-url "$REMOTE" >/dev/null 2>&1 || die "Git remote '$REMOTE' is not configured."

    CURRENT_BRANCH=$(git branch --show-current)
    [[ -n "$CURRENT_BRANCH" ]] || die "Detached HEAD; switch to a feature branch first."
    [[ "$CURRENT_BRANCH" == feat/* || "$CURRENT_BRANCH" == feature/* ]] ||
        die "Current branch must start with feat/ or feature/ (currently '$CURRENT_BRANCH')."
    [[ -z "$(git status --porcelain)" ]] || {
        git status --short >&2
        die "Working tree is not clean; commit or stash changes before releasing."
    }

    [[ -f "$SETTINGS_FILE" ]] || die "conf/settings.cfg is required for a release."
    local current_version
    PROJECT_NAME=$(sed -nE 's/^PROJECT_NAME="([^"]+)"$/\1/p' "$SETTINGS_FILE")
    current_version=$(sed -nE 's/^PROJECT_VERSION="([^"]+)"$/\1/p' "$SETTINGS_FILE")
    [[ -n "$PROJECT_NAME" ]] ||
        die "PROJECT_NAME is missing or invalid in conf/settings.cfg."
    [[ "$current_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?(\+[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] ||
        die "PROJECT_VERSION in conf/settings.cfg is missing or invalid: $current_version"
    [[ "$current_version" != "$NEW_VERSION" ]] ||
        die "PROJECT_VERSION is already $NEW_VERSION; choose a new release version."

    if git grep -I -n -E -- '-----BEGIN (ENCRYPTED |RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----' -- .; then
        die "A private-key PEM marker was found in tracked files; remove the secret before releasing."
    fi

    if git ls-files | grep -E '(^|/)(password|passphrase)(\.[^/]*)?$' >&2; then
        die "A likely password/passphrase file is tracked; remove it before releasing."
    fi

    ref_exists "refs/heads/$MAIN_BRANCH" || die "Local branch '$MAIN_BRANCH' does not exist."
    ref_exists "refs/heads/$DEV_BRANCH" || die "Local branch '$DEV_BRANCH' does not exist."

    info "Fetching release refs from $REMOTE..."
    git fetch --prune "$REMOTE"

    ref_exists "refs/remotes/$REMOTE/$MAIN_BRANCH" ||
        die "Remote branch '$REMOTE/$MAIN_BRANCH' does not exist."
    [[ "$(git rev-parse "$MAIN_BRANCH")" == "$(git rev-parse "$REMOTE/$MAIN_BRANCH")" ]] ||
        die "Local '$MAIN_BRANCH' differs from '$REMOTE/$MAIN_BRANCH'; reconcile it first."

    if ref_exists "refs/remotes/$REMOTE/$DEV_BRANCH"; then
        [[ "$(git rev-parse "$DEV_BRANCH")" == "$(git rev-parse "$REMOTE/$DEV_BRANCH")" ]] ||
            die "Local '$DEV_BRANCH' differs from '$REMOTE/$DEV_BRANCH'; reconcile it first."
    else
        warn "Remote '$REMOTE/$DEV_BRANCH' does not exist; this release will create it."
    fi

    ! ref_exists "refs/heads/$RELEASE_BRANCH" || die "Local branch '$RELEASE_BRANCH' already exists."
    ! ref_exists "refs/remotes/$REMOTE/$RELEASE_BRANCH" || die "Remote branch '$REMOTE/$RELEASE_BRANCH' already exists."
    ! ref_exists "refs/tags/$TAG_NAME" || die "Tag '$TAG_NAME' already exists locally."
    ! git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$TAG_NAME" >/dev/null 2>&1 ||
        die "Tag '$TAG_NAME' already exists on '$REMOTE'."
    ! ref_exists "refs/heads/$NEXT_FEATURE_BRANCH" || die "Local branch '$NEXT_FEATURE_BRANCH' already exists."
    ! ref_exists "refs/remotes/$REMOTE/$NEXT_FEATURE_BRANCH" ||
        die "Remote branch '$REMOTE/$NEXT_FEATURE_BRANCH' already exists."

    git merge-base --is-ancestor "$MAIN_BRANCH" "$DEV_BRANCH" ||
        die "'$DEV_BRANCH' does not contain '$MAIN_BRANCH'; reconcile the branches first."
}

confirm_release() {
    printf '\nRelease summary:\n'
    printf '  Project:       %s\n' "$PROJECT_NAME"
    printf '  Source:        %s\n' "$CURRENT_BRANCH"
    printf '  Release:       %s (%s)\n' "$RELEASE_BRANCH" "$TAG_NAME"
    printf '  Next branch:   %s\n' "$NEXT_FEATURE_BRANCH"
    printf '  Remote:        %s\n\n' "$(git remote get-url "$REMOTE")"

    [[ -t 0 ]] || die "Confirmation requires an interactive terminal."
    read -r -p "Create and push this release? [y/N] " reply
    [[ "$reply" == y || "$reply" == Y ]] || { warn "Release cancelled."; exit 0; }
}

merge_no_ff() {
    local source=$1 message=$2
    info "Merging '$source' into '$(git branch --show-current)'..."
    git merge --no-ff "$source" -m "$message"
}

update_changelog() {
    local changelog="$PROJECT_DIR/CHANGELOG.md"
    local release_date release_heading temp_file

    [[ -f "$changelog" ]] || die "CHANGELOG.md is required for a release."
    grep -Fxq '## [Unreleased]' "$changelog" ||
        die "CHANGELOG.md does not contain the required '## [Unreleased]' heading."

    release_date=$(date '+%Y-%m-%d %H:%M %Z')
    release_heading="## [Release $NEW_VERSION] - $release_date"
    temp_file=$(mktemp "$PROJECT_DIR/.CHANGELOG.md.XXXXXX")

    if ! awk -v release_heading="$release_heading" '
        /^## \[Unreleased\]$/ {
            print
            print ""
            print release_heading
            next
        }
        { print }
    ' "$changelog" >"$temp_file"; then
        rm -f -- "$temp_file"
        die "Failed to update CHANGELOG.md."
    fi

    chmod --reference="$changelog" "$temp_file"
    mv -- "$temp_file" "$changelog"
    git add -- CHANGELOG.md
    success "Updated CHANGELOG.md for $TAG_NAME."
}

update_project_version() {
    local temp_file
    temp_file=$(mktemp "$PROJECT_DIR/conf/.settings.cfg.XXXXXX")

    if ! awk -v version="$NEW_VERSION" '
        /^PROJECT_VERSION="[^"]+"$/ {
            print "PROJECT_VERSION=\"" version "\""
            next
        }
        { print }
    ' "$SETTINGS_FILE" >"$temp_file"; then
        rm -f -- "$temp_file"
        die "Failed to update PROJECT_VERSION in conf/settings.cfg."
    fi

    chmod --reference="$SETTINGS_FILE" "$temp_file"
    mv -- "$temp_file" "$SETTINGS_FILE"
    git add -- conf/settings.cfg
    success "Updated PROJECT_VERSION to $NEW_VERSION."
}

create_release() {
    git switch "$DEV_BRANCH"
    merge_no_ff "$CURRENT_BRANCH" "Merge $CURRENT_BRANCH into $DEV_BRANCH for $TAG_NAME"

    git switch -c "$RELEASE_BRANCH"
    update_project_version
    update_changelog
    git commit -m "Update release metadata for $TAG_NAME"

    git switch "$MAIN_BRANCH"
    merge_no_ff "$RELEASE_BRANCH" "Release $TAG_NAME: $RELEASE_MESSAGE"
    git tag -a "$TAG_NAME" -m "$RELEASE_MESSAGE"

    git switch "$DEV_BRANCH"
    merge_no_ff "$MAIN_BRANCH" "Merge $TAG_NAME back into $DEV_BRANCH"

    info "Pushing release refs atomically..."
    git push --atomic "$REMOTE" \
        "refs/heads/$MAIN_BRANCH:refs/heads/$MAIN_BRANCH" \
        "refs/heads/$DEV_BRANCH:refs/heads/$DEV_BRANCH" \
        "refs/heads/$RELEASE_BRANCH:refs/heads/$RELEASE_BRANCH" \
        "refs/tags/$TAG_NAME:refs/tags/$TAG_NAME"

    git switch -c "$NEXT_FEATURE_BRANCH"
}

main() {
    cd -- "$PROJECT_DIR"
    if [[ ${1:-} == -h || ${1:-} == --help ]]; then usage; exit 0; fi
    validate_arguments "$@"
    preflight
    confirm_release
    create_release

    success "Release $TAG_NAME was published successfully."
    success "Now on new feature branch: $NEXT_FEATURE_BRANCH"
    info "Deploy Paris from the signed-off Git tag '$TAG_NAME', not from a working branch."
}

main "$@"
