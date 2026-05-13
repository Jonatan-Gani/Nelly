#!/usr/bin/env bash
# lib/push.sh — push a local file or directory into a running app, hot.
#
#   nelly push <name> <app> <src> [dst]
#
# <src> is a local path (file or directory).
# <dst> defaults to the basename of <src>, placed under /home/apps/<app>/.
#
# Useful for iterating on a script without rebuilding the image. The change is
# ephemeral inside the container — re-deploy to make it permanent (after
# committing it upstream or saving it in your local source path).
set -euo pipefail

DEPLOY_DIR="$1"; shift
APP="${1:-}"; shift || true
SRC="${1:-}"; shift || true
DST="${1:-}"; shift || true

LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

[[ -n "$APP" && -n "$SRC" ]] || die "usage: nelly push <name> <app> <src> [dst]"
[[ -e "$SRC" ]] || die "no such path: $SRC"

require_cmd docker
CN="$(container_name_for "$DEPLOY_DIR")"
docker inspect "$CN" >/dev/null 2>&1 || die "container $CN not running"

# Resolve destination
if [[ -z "$DST" ]]; then
    DST="/home/apps/$APP/$(basename "$SRC")"
elif [[ "$DST" != /* ]]; then
    DST="/home/apps/$APP/$DST"
fi

info "copying $SRC → $CN:$DST"
docker cp "$SRC" "$CN:$DST"
info "done (ephemeral until next deploy)"
