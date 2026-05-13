#!/usr/bin/env bash
# Print container status + pinned commit per app.
set -euo pipefail

DEPLOY_DIR="$1"
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
LOCKFILE="$DEPLOY_DIR/def/commits.lock.json"
CONTAINER_NAME="$(jqget "$CONFIG" '.container_name' 'nelly')"

echo "deployment : $DEPLOY_DIR"
echo "container  : $CONTAINER_NAME"
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    state="$(docker inspect -f '{{.State.Status}} (started {{.State.StartedAt}})' "$CONTAINER_NAME")"
    echo "state      : $state"
else
    echo "state      : not running"
fi

echo "image      : $(cat "$DEPLOY_DIR/def/last_image.txt" 2>/dev/null || echo '(none built)')"

if [[ -f "$LOCKFILE" ]]; then
    echo "pinned commits:"
    jq -r 'to_entries[] | "  \(.key) @ \(.value)"' "$LOCKFILE"
else
    echo "pinned commits: (no lockfile yet — run: nelly fetch $(basename "$DEPLOY_DIR"))"
fi
