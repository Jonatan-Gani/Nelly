#!/usr/bin/env bash
# lib/explain.sh — print a human-readable summary of what a deployment will do.
set -euo pipefail
DEPLOY_DIR="$1"
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
[[ -f "$CONFIG" ]] || die "no config at $CONFIG"

_bold() { [[ -t 1 ]] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"; }
_dim()  { [[ -t 1 ]] && printf '\033[2m%s\033[0m' "$1" || printf '%s' "$1"; }

name="$(basename "$DEPLOY_DIR")"
container="$(jqget "$CONFIG" '.container_name' "$name")"
image="$(jqget "$CONFIG" '.image_name' "$name")"
n_apps="$(jq '.apps | length' "$CONFIG")"

echo
echo "$(_bold "Deployment '$name'") → $(_dim "containers/$name/")"
echo "  container : $container"
echo "  image     : $image"
echo "  apps      : $n_apps"

# resources
cpus="$(jqget   "$CONFIG" '.resources.cpus' '(unlimited)')"
mem="$(jqget    "$CONFIG" '.resources.memory' '(unlimited)')"
pids="$(jqget   "$CONFIG" '.resources.pids_limit' '(unlimited)')"
restart="$(jqget "$CONFIG" '.restart' 'unless-stopped')"
echo "  resources : cpus=$cpus  memory=$mem  pids_limit=$pids  restart=$restart"

# network
nname="$(jqget "$CONFIG" '.network.network_name' '')"
ip="$(jqget    "$CONFIG" '.network.static_ip' '')"
ports="$(jq -r '.network.ports[]?' "$CONFIG" | paste -sd' ' || true)"
if [[ -n "$nname" || -n "$ip" || -n "$ports" ]]; then
    echo "  network   : ${nname:-default}  ip=${ip:-auto}  ports=${ports:-none}"
fi

# secrets
env_file="$DEPLOY_DIR/def/.env"
if [[ -f "$env_file" ]]; then
    n_secrets="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/' "$env_file" | wc -l | tr -d ' ')"
    echo "  secrets   : $n_secrets key(s) in def/.env"
else
    echo "  secrets   : (no .env yet — use: nelly secrets set $name KEY=value)"
fi

# apps
if (( n_apps == 0 )); then
    echo
    echo "$(_dim "No apps configured yet.")"
    echo "  $(_bold "nelly app add $name")"
    exit 0
fi

echo
echo "$(_bold 'Apps')"
i=0
while (( i < n_apps )); do
    app="$(jq -c ".apps[$i]" "$CONFIG")"
    aname="$(echo "$app" | jq -r '.app_name')"
    stype="$(echo "$app" | jq -r '.source.type // (if .git_url then "git" else "?" end)')"
    case "$stype" in
        git)
            url="$(echo "$app" | jq -r '.source.url // .git_url')"
            ref="$(echo "$app" | jq -r '.source.ref // .ref // .branch // "main"')"
            srcdesc="git: $url @ $ref"
            ;;
        local)
            path="$(echo "$app" | jq -r '.source.path')"
            srcdesc="local: $path"
            ;;
        *) srcdesc="(unknown source)" ;;
    esac
    schedule="$(echo "$app" | jq -r '.schedule  // "(unscheduled)"')"
    entrypoint="$(echo "$app" | jq -r '.entrypoint // "(no entrypoint)"')"

    echo "  $(_bold "$aname")"
    echo "    source    : $srcdesc"
    echo "    schedule  : $schedule"
    echo "    runs      : python $entrypoint  $(_dim '(inside /opt/venvs/'"$aname"'/bin/python)')"
    i=$((i+1))
done

echo
echo "$(_dim "Ready? → nelly doctor $name  &&  nelly deploy $name")"
