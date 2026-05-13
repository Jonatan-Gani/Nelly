#!/usr/bin/env bash
# lib/status.sh — show one deployment's container + pinned commits.
set -euo pipefail

DEPLOY_DIR="$1"
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
LOCKFILE="$DEPLOY_DIR/def/commits.lock.json"
[[ -f "$CONFIG" ]] || die "no config at $CONFIG"
CONTAINER_NAME="$(jqget "$CONFIG" '.container_name')"

if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
    state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo absent)"
    health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo none)"
    started="$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null || echo '')"
    image="$(cat "$DEPLOY_DIR/def/last_image.txt" 2>/dev/null || echo '')"
    pinned='{}'; [[ -f "$LOCKFILE" ]] && pinned="$(cat "$LOCKFILE")"
    jq -nc \
        --arg c "$CONTAINER_NAME" --arg s "$state" --arg h "$health" \
        --arg st "$started" --arg i "$image" --argjson p "$pinned" \
        '{container:$c, state:$s, health:$h, started:$st, image:$i, pinned:$p}'
    exit 0
fi

echo "deployment : $(basename "$DEPLOY_DIR")"
echo "container  : $CONTAINER_NAME"
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")"
    started="$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER_NAME")"
    health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo n/a)"
    echo "state      : $state (started $started)"
    echo "health     : $health"
else
    echo "state      : not running"
fi
echo "image      : $(cat "$DEPLOY_DIR/def/last_image.txt" 2>/dev/null || echo '(none built)')"
echo "schedules  :"
jq -r '.apps[] | "  \(.app_name): \(.schedule // "(unscheduled)")  → \(.entrypoint // "")"' "$CONFIG"
if [[ -f "$LOCKFILE" ]]; then
    echo "pinned     :"
    jq -r 'to_entries[] | "  \(.key) @ \(.value)"' "$LOCKFILE"
fi
