#!/usr/bin/env bash
# lib/list.sh — list every deployment under containers/, with status.
set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

require_cmd jq docker
[[ -n "${NELLY_ROOT:-}" ]] || die "NELLY_ROOT not set"

results='[]'
while IFS= read -r name; do
    [[ "$name" == "template" ]] && continue
    dir="$NELLY_ROOT/containers/$name"
    [[ -f "$dir/def/config.json" ]] || continue
    cn="$(jqget "$dir/def/config.json" '.container_name' "$name")"
    apps="$(jq -r '.apps | length' "$dir/def/config.json")"
    state="$(docker inspect -f '{{.State.Status}}' "$cn" 2>/dev/null || echo "absent")"
    image="$(cat "$dir/def/last_image.txt" 2>/dev/null || echo '(not built)')"
    entry="$(jq -nc \
        --arg name "$name" --arg container "$cn" --arg state "$state" \
        --arg image "$image" --argjson apps "$apps" \
        '{deployment:$name, container:$container, state:$state, image:$image, apps:$apps}')"
    results="$(echo "$results" | jq --argjson e "$entry" '. + [$e]')"
done < <(list_deployments)

if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
    echo "$results"
else
    if [[ "$(echo "$results" | jq 'length')" == "0" ]]; then
        info "no deployments yet — try: nelly init <name>"
        exit 0
    fi
    printf '%-20s %-22s %-10s %-4s %s\n' "DEPLOYMENT" "CONTAINER" "STATE" "APPS" "IMAGE"
    echo "$results" | jq -r '.[] | [.deployment, .container, .state, (.apps|tostring), .image] | @tsv' \
        | while IFS=$'\t' read -r d c s a i; do
            printf '%-20s %-22s %-10s %-4s %s\n' "$d" "$c" "$s" "$a" "$i"
        done
fi
