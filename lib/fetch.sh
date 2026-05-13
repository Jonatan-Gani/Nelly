#!/usr/bin/env bash
# lib/fetch.sh — populate apps/ from each app's source (git or local).
# Writes def/commits.lock.json with the resolved revision per app.
set -euo pipefail

DEPLOY_DIR="$1"
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=source.sh
source "$LIB/source.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
APPS_DIR="$DEPLOY_DIR/apps"
LOG_FILE="$DEPLOY_DIR/logs/fetch.log"
LOCKFILE="$DEPLOY_DIR/def/commits.lock.json"

mkdir -p "$APPS_DIR" "$(dirname "$LOG_FILE")"
exec > >(log_to "$LOG_FILE") 2>&1

require_cmd jq
validate_config "$DEPLOY_DIR"

[[ -f "$LOCKFILE" ]] || echo '{}' > "$LOCKFILE"

mapfile -t APPS < <(jq -c '.apps[]' "$CONFIG")

for app in "${APPS[@]}"; do
    name="$(echo "$app" | jq -r '.app_name')"
    target="$APPS_DIR/$name"
    info "fetching $name"
    rev="$(fetch_source "$app" "$target")"
    info "  resolved $name @ $rev"
    jq_inplace "$LOCKFILE" --arg n "$name" --arg r "$rev" '. + {($n): $r}'
done

# Drop lockfile entries for apps that no longer exist in config
jq_inplace "$LOCKFILE" --argjson keep "$(jq '[.apps[].app_name]' "$CONFIG")" \
    'with_entries(select(.key as $k | $keep | index($k)))'

info "fetch complete; $(jq 'length' "$LOCKFILE") app(s) pinned in $LOCKFILE"
