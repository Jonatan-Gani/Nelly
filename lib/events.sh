#!/usr/bin/env bash
# lib/events.sh — stream docker events for a deployment's container.
#
#   nelly events <name>            tail events from now
#   nelly events <name> --since 1h start from a relative point
#   nelly events <name> --json     machine-readable
set -euo pipefail
DEPLOY_DIR="$1"; shift
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

SINCE=""
while (( $# > 0 )); do
    case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        --json)  shift ;;   # already handled globally
        *) shift ;;
    esac
done

CN="$(container_name_for "$DEPLOY_DIR")"

declare -a ARGS=(events --filter "container=$CN")
[[ -n "$SINCE" ]] && ARGS+=(--since "$SINCE")
if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
    ARGS+=(--format '{{json .}}')
else
    ARGS+=(--format '{{.Time}}  {{.Action}}  {{.Actor.Attributes.exitCode}}  {{.Actor.Attributes.image}}')
fi

info "streaming docker events for $CN (Ctrl-C to stop)"
exec docker "${ARGS[@]}"
