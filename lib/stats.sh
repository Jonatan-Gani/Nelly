#!/usr/bin/env bash
# lib/stats.sh — `ps` and `stats` views over nelly-managed containers.
set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

sub="${1:-ps}"
require_cmd docker

case "$sub" in
    ps)
        # Show only nelly-managed containers.
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
            docker ps -a --filter "label=nelly.managed=true" \
                --format '{{json .}}' \
                | jq -s '.'
        else
            docker ps -a --filter "label=nelly.managed=true" \
                --format 'table {{.Label "nelly.deployment"}}\t{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
        fi
        ;;
    stats)
        # Live resource usage; one-shot via --no-stream.
        local_names=()
        while IFS= read -r n; do local_names+=("$n"); done < <(docker ps --filter "label=nelly.managed=true" --format '{{.Names}}')
        if (( ${#local_names[@]} == 0 )); then
            info "no running nelly containers"
            exit 0
        fi
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
            docker stats --no-stream --format '{{json .}}' "${local_names[@]}" | jq -s '.'
        else
            docker stats --no-stream "${local_names[@]}"
        fi
        ;;
    *)
        die "usage: stats.sh {ps|stats}"
        ;;
esac
