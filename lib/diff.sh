#!/usr/bin/env bash
# lib/diff.sh — show what would change on the next `nelly deploy`.
# Compares the current lockfile against what `fetch` would resolve.
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
LOCKFILE="$DEPLOY_DIR/def/commits.lock.json"
validate_config "$DEPLOY_DIR"
[[ -f "$LOCKFILE" ]] || echo '{}' > "$LOCKFILE"

mapfile -t APPS < <(jq -c '.apps[]' "$CONFIG")

declare -a CHANGES=()
for app in "${APPS[@]}"; do
    name="$(echo "$app" | jq -r '.app_name')"
    old="$(jq -r --arg n "$name" '.[$n] // "(none)"' "$LOCKFILE")"

    src="$(normalize_app_source "$app")"
    type="$(echo "$src" | jq -r '.type')"
    new=""
    case "$type" in
        git)
            url="$(echo "$src" | jq -r '.url')"
            ref="$(echo "$src" | jq -r '.ref // "main"')"
            new="$(git ls-remote -- "$url" "$ref" 2>/dev/null | awk 'NR==1{print $1}')"
            [[ -n "$new" ]] || new="(unresolved: $ref)"
            ;;
        local)
            new="(local, always re-synced)"
            ;;
    esac

    if [[ "$old" != "$new" && "$new" != "(local, always re-synced)" ]]; then
        CHANGES+=("$name: $old → $new")
    elif [[ "$new" == "(local, always re-synced)" ]]; then
        CHANGES+=("$name: $new")
    else
        CHANGES+=("$name: up-to-date ($old)")
    fi
done

if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
    printf '%s\n' "${CHANGES[@]}" | jq -R . | jq -s .
else
    printf '%s\n' "${CHANGES[@]}"
fi
