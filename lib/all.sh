#!/usr/bin/env bash
# lib/all.sh — run a nelly command across multiple deployments.
#
#   nelly all <cmd> [--tag T]... [-- <cmd-args>...]
#   nelly all list
#   nelly all status
#   nelly all deploy           --tag prod        # all deployments tagged "prod"
#   nelly all restart          --tag prod --tag critical
#
# Tag filters are AND-ed: all of the given tags must appear in
# config.tags[] for a deployment to be included. With no --tag, every
# deployment under containers/ is included.
#
# Each invocation runs `bin/nelly <cmd> <name> [args]` sequentially.
# Non-zero exits are reported but do not stop the loop unless --fail-fast.

set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

NELLY_BIN="$NELLY_ROOT/bin/nelly"

usage() {
    cat <<'EOF'
nelly all <cmd> [--tag T]... [--fail-fast] [-- <cmd-args>...]

Pre-built shortcuts:
  nelly all list                # what deployments are there (filtered by --tag)
  nelly all status              # show status of each
  nelly all deploy              # deploy each (sequentially)
  nelly all restart             # restart each
EOF
}

CMD="${1:-}"
[[ -n "$CMD" ]] || { usage; exit 2; }
shift

declare -a TAGS=()
FAIL_FAST=0
declare -a PASS_ARGS=()
while (( $# > 0 )); do
    case "$1" in
        --tag)        TAGS+=("$2"); shift 2 ;;
        --fail-fast)  FAIL_FAST=1; shift ;;
        --)           shift; PASS_ARGS+=("$@"); break ;;
        *)            PASS_ARGS+=("$1"); shift ;;
    esac
done

# Build the list of matching deployments.
declare -a NAMES=()
while IFS= read -r name; do
    cfg="$NELLY_ROOT/containers/$name/def/config.json"
    [[ -f "$cfg" ]] || continue
    if (( ${#TAGS[@]} > 0 )); then
        match=1
        for tag in "${TAGS[@]}"; do
            if ! jq -e --arg t "$tag" '(.tags // []) | index($t)' "$cfg" >/dev/null; then
                match=0; break
            fi
        done
        (( match )) || continue
    fi
    NAMES+=("$name")
done < <(list_deployments)

if (( ${#NAMES[@]} == 0 )); then
    info "no deployments matched"
    exit 0
fi

# Special case: `nelly all list` summarises matches with a table.
if [[ "$CMD" == "list" ]]; then
    printf '%-22s %s\n' "DEPLOYMENT" "TAGS"
    for n in "${NAMES[@]}"; do
        tags="$(jq -r '(.tags // []) | join(",")' "$NELLY_ROOT/containers/$n/def/config.json")"
        printf '%-22s %s\n' "$n" "${tags:-(none)}"
    done
    exit 0
fi

FAIL=0
for n in "${NAMES[@]}"; do
    echo
    info "==> $n: nelly $CMD ${PASS_ARGS[*]:-}"
    if ! "$NELLY_BIN" "$CMD" "$n" "${PASS_ARGS[@]}"; then
        FAIL=$((FAIL+1))
        warn "$n: command failed"
        (( FAIL_FAST )) && exit 1
    fi
done

echo
if (( FAIL == 0 )); then
    info "all ${#NAMES[@]} deployment(s) completed"
else
    err "$FAIL of ${#NAMES[@]} deployment(s) failed"
    exit 1
fi
