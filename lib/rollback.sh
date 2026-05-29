#!/usr/bin/env bash
# lib/rollback.sh — switch the running container to a prior image tag.
#
#   nelly rollback <name>             → most recent prior build
#   nelly rollback <name> --to <tag>  → specific image (e.g. mybot:abc123)
#   nelly rollback <name> --list      → list available build history
set -euo pipefail

DEPLOY_DIR="$1"; shift
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

HISTORY="$DEPLOY_DIR/def/build_history.json"
[[ -f "$HISTORY" ]] || die "no build history yet for $(basename "$DEPLOY_DIR")"

ACTION="rollback"
TARGET=""
while (( $# > 0 )); do
    case "$1" in
        --to)   TARGET="$2"; shift 2 ;;
        --list) ACTION="list"; shift ;;
        *) die "unknown flag: $1" ;;
    esac
done

if [[ "$ACTION" == "list" ]]; then
    if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
        cat "$HISTORY"
    else
        jq -r '.[] | "\(.built_at)  \(.image)"' "$HISTORY"
    fi
    exit 0
fi

if [[ -z "$TARGET" ]]; then
    # Default: second-to-last entry (i.e. the previous build).
    TARGET="$(jq -r '
        if length >= 2 then .[-2].image
        else error("no prior build to roll back to")
        end' "$HISTORY")"
fi

info "rolling back to $TARGET"
# Record the rollback as a release so the deploy history reflects it (parity
# with `nelly release restore`, which already does this).
rel_id="$("$LIB/release.sh" create "$DEPLOY_DIR")"
if "$LIB/run.sh" "$DEPLOY_DIR" --image "$TARGET"; then
    echo "$TARGET" > "$DEPLOY_DIR/def/last_image.txt"
    "$LIB/release.sh" finalize "$DEPLOY_DIR" "$rel_id" --outcome rolled_back --image "$TARGET"
    info "container now running $TARGET"
else
    rc=$?
    "$LIB/release.sh" finalize "$DEPLOY_DIR" "$rel_id" --outcome failed || true
    die "rollback to $TARGET failed (exit $rc)"
fi
