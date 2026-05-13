#!/usr/bin/env bash
# Clone or refresh each app's repo into apps/<name> at a pinned commit.
set -euo pipefail

DEPLOY_DIR="$1"
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
APPS_DIR="$DEPLOY_DIR/apps"
LOG_FILE="$DEPLOY_DIR/logs/fetch.log"
mkdir -p "$APPS_DIR" "$(dirname "$LOG_FILE")"
exec > >(log_to "$LOG_FILE") 2>&1

require_cmd jq git rsync
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

# Read deployment commit lockfile (optional, written by us).
LOCKFILE="$DEPLOY_DIR/def/commits.lock.json"
[[ -f "$LOCKFILE" ]] || echo '{}' > "$LOCKFILE"

mapfile -t APPS < <(jq -c '.apps[]' "$CONFIG")
[[ ${#APPS[@]} -gt 0 ]] || die "no apps defined in $CONFIG"

for app in "${APPS[@]}"; do
    name="$(echo "$app"     | jq -r '.app_name')"
    url="$(echo "$app"      | jq -r '.git_url')"
    ref="$(echo "$app"      | jq -r '.ref // .branch // "main"')"

    [[ "$name" != "null" && -n "$name" ]] || die "app missing app_name"
    [[ "$url"  != "null" && -n "$url"  ]] || die "app $name missing git_url"

    target="$APPS_DIR/$name"
    info "fetching $name from $url@$ref"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    git clone --quiet --depth 50 --branch "$ref" "$url" "$tmp" 2>/dev/null \
        || git clone --quiet "$url" "$tmp"
    ( cd "$tmp" && git checkout --quiet "$ref" )

    sha="$(cd "$tmp" && git rev-parse HEAD)"
    info "  pinned $name @ $sha"

    rm -rf "$target"
    mkdir -p "$target"
    rsync -a --exclude='.git' "$tmp/" "$target/"
    rm -rf "$tmp"
    trap - EXIT

    # Update lockfile
    jq --arg n "$name" --arg s "$sha" '. + {($n): $s}' "$LOCKFILE" > "$LOCKFILE.tmp"
    mv "$LOCKFILE.tmp" "$LOCKFILE"
done

info "fetch complete; lockfile at $LOCKFILE"
