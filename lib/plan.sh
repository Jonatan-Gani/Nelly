#!/usr/bin/env bash
# lib/plan.sh — print what `nelly deploy` would do, without side effects.
set -euo pipefail
DEPLOY_DIR="$1"
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"
# shellcheck source=source.sh
source "$LIB/source.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
LOCKFILE="$DEPLOY_DIR/def/commits.lock.json"
validate_config "$DEPLOY_DIR" >/dev/null

name="$(basename "$DEPLOY_DIR")"
container="$(jqget "$CONFIG" '.container_name')"
image="$(jqget "$CONFIG" '.image_name')"

_bold() { [[ -t 1 ]] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"; }
_dim()  { [[ -t 1 ]] && printf '\033[2m%s\033[0m' "$1" || printf '%s' "$1"; }

echo
echo "$(_bold "Plan for: $name")"
echo

echo "$(_bold '1. fetch')"
mapfile -t APPS < <(jq -c '.apps[]' "$CONFIG")
for app in "${APPS[@]}"; do
    aname="$(echo "$app" | jq -r '.app_name')"
    stype="$(echo "$app" | jq -r '.source.type // (if .git_url then "git" else "?" end)')"
    case "$stype" in
        git)
            url="$(echo "$app" | jq -r '.source.url // .git_url')"
            ref="$(echo "$app" | jq -r '.source.ref // .ref // .branch // "main"')"
            old="(none)"
            [[ -f "$LOCKFILE" ]] && old="$(jq -r --arg n "$aname" '.[$n] // "(none)"' "$LOCKFILE")"
            new="(unknown)"
            if command -v git >/dev/null 2>&1; then
                new="$(git ls-remote "$url" "$ref" 2>/dev/null | awk 'NR==1{print $1}')"
                [[ -z "$new" ]] && new="(unresolved: $ref)"
            fi
            if [[ "$old" == "$new" ]]; then
                echo "   $aname: $(_dim 'up-to-date') $old"
            else
                echo "   $aname: $old → $new"
            fi
            ;;
        local)
            path="$(echo "$app" | jq -r '.source.path')"
            echo "   $aname: local re-sync from $path"
            ;;
    esac
done

echo
echo "$(_bold '2. build')"
echo "   image:    $image:<new-lockfile-hash>"
echo "   packages: $(jq -r '.packages | join(", ")' "$CONFIG")"
echo "   venvs:    $(jq -r '[.apps[].app_name | "/opt/venvs/" + .] | join(", ")' "$CONFIG")"
echo "   crontab:  $(jq -r '[.apps[] | select((.schedule//"") != "") | .app_name] | "\(length) scheduled app(s)"' "$CONFIG")"

echo
echo "$(_bold '3. run')"
echo "   container: $container"
cpus="$(jqget "$CONFIG"     '.resources.cpus' '(default)')"
mem="$(jqget "$CONFIG"      '.resources.memory' '(default)')"
restart="$(jqget "$CONFIG"  '.restart' 'unless-stopped')"
echo "   resources: cpus=$cpus  memory=$mem  restart=$restart"

nname="$(jqget "$CONFIG" '.network.network_name' '')"
[[ -n "$nname" ]] && echo "   network:   $nname"

mapfile -t XNETS < <(jq -r '.network.extra_networks[]?' "$CONFIG")
(( ${#XNETS[@]} > 0 )) && echo "   extra:     ${XNETS[*]}"

env_file="$DEPLOY_DIR/def/.env"
if [[ -f "$env_file" ]]; then
    n_secrets="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/' "$env_file" | wc -l | tr -d ' ')"
    echo "   secrets:   $n_secrets key(s) from def/.env"
else
    echo "   secrets:   (none — no def/.env)"
fi

echo
echo "$(_bold '4. prune')"
echo "   delete log files older than $(jqget "$CONFIG" '.log_retention_days' '7') days"

echo
echo "$(_dim "Run for real: nelly deploy $name")"
