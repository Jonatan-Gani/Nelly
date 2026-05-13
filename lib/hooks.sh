#!/usr/bin/env bash
# lib/hooks.sh — run user-defined lifecycle hooks.
#
# Hooks are paths in config.hooks.{pre_deploy,post_deploy,on_failure}.
# Relative paths resolve against the deployment directory. Each hook gets:
#   NELLY_DEPLOYMENT, NELLY_DEPLOY_DIR, NELLY_HOOK (name), NELLY_IMAGE (best-effort)
#
# Failures in pre_deploy abort the deploy. Failures in post_deploy and
# on_failure are logged but never abort.

set -euo pipefail
# Use BASH_SOURCE so this works whether we're executed or sourced.
_HOOKS_LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# Only load common.sh if it isn't already (the parent script may have done it).
if ! declare -F info >/dev/null 2>&1; then
    # shellcheck source=common.sh
    source "$_HOOKS_LIB/common.sh"
fi

run_hook() {
    local deploy_dir="$1" hook="$2"
    local config="$deploy_dir/def/config.json"
    [[ -f "$config" ]] || return 0
    local path; path="$(jqget "$config" ".hooks.$hook" "")"
    [[ -n "$path" ]] || return 0

    local resolved="$path"
    [[ "$path" != /* ]] && resolved="$deploy_dir/$path"
    [[ -x "$resolved" ]] || { warn "hook '$hook' not executable: $resolved (skipping)"; return 0; }

    local image=""
    [[ -f "$deploy_dir/def/last_image.txt" ]] && image="$(cat "$deploy_dir/def/last_image.txt")"

    info "running hook: $hook ($path)"
    if NELLY_DEPLOYMENT="$(basename "$deploy_dir")" \
       NELLY_DEPLOY_DIR="$deploy_dir" \
       NELLY_HOOK="$hook" \
       NELLY_IMAGE="$image" \
       "$resolved"; then
        return 0
    else
        local rc=$?
        warn "hook '$hook' exited $rc"
        return $rc
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ $# -ge 2 ]] || die "usage: hooks.sh <deploy_dir> <hook_name>"
    run_hook "$@"
fi
