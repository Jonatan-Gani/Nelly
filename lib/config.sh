#!/usr/bin/env bash
# lib/config.sh — validate, read, and edit a deployment's config.json.
#
# Subcommands (called from bin/nelly):
#   validate <deploy_dir>
#   show     <deploy_dir>            # prints config.json as JSON
#   get      <deploy_dir> <jq-path>  # e.g. ".container_name"
#   set      <deploy_dir> <jq-path> <value>     # JSON-typed if parseable, else string
#   edit     <deploy_dir>            # open in $EDITOR, validate before saving
#   add-app  <deploy_dir> --name N (--git URL --ref R | --local PATH) \
#                        --schedule "* * * * *" --entrypoint FILE
#   remove-app   <deploy_dir> <app_name>
#   set-schedule <deploy_dir> <app_name> "<cron>"

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

# ---- validation ------------------------------------------------------------

validate_config() {
    local deploy_dir="$1"
    local config="$deploy_dir/def/config.json"
    [[ -f "$config" ]] || die "config not found: $config"

    require_cmd jq

    jq -e . "$config" >/dev/null \
        || die "config is not valid JSON: $config"

    local errors=()

    _check() {
        local expr="$1" msg="$2"
        if [[ "$(jq -r "$expr" "$config")" != "true" ]]; then
            errors+=("$msg")
        fi
    }

    _check '(.container_name | type == "string" and length > 0)' \
        '.container_name must be a non-empty string'
    _check '(.image_name | type == "string" and length > 0)' \
        '.image_name must be a non-empty string'
    _check '(.apps | type == "array" and length > 0)' \
        '.apps must be a non-empty array'

    # container_name and image_name: docker-safe characters
    local cname iname
    cname="$(jqget "$config" '.container_name')"
    iname="$(jqget "$config" '.image_name')"
    [[ "$cname" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]] \
        || errors+=(".container_name '$cname' is not a valid docker name")
    [[ "$iname" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] \
        || errors+=(".image_name '$iname' is not a valid docker image name (lowercase, [a-z0-9._-])")

    # Validate each app
    local i=0
    local n; n="$(jq '.apps | length' "$config")"
    while (( i < n )); do
        local prefix=".apps[$i]"
        local app_name; app_name="$(jq -r "$prefix.app_name // empty" "$config")"
        [[ -n "$app_name" ]] || errors+=("$prefix.app_name missing")
        [[ "$app_name" =~ ^[a-zA-Z0-9_-]+$ ]] || \
            errors+=("$prefix.app_name '$app_name' must match [a-zA-Z0-9_-]+")

        # source: either new-style .source or legacy .git_url
        local has_src; has_src="$(jq "($prefix.source != null) or ($prefix.git_url != null)" "$config")"
        [[ "$has_src" == "true" ]] || errors+=("$prefix needs .source or legacy .git_url")

        if [[ "$(jq "$prefix.source != null" "$config")" == "true" ]]; then
            local stype; stype="$(jq -r "$prefix.source.type" "$config")"
            case "$stype" in
                git)   [[ "$(jq "$prefix.source.url"  "$config")" != "null" ]] || errors+=("$prefix.source.url missing");;
                local) [[ "$(jq "$prefix.source.path" "$config")" != "null" ]] || errors+=("$prefix.source.path missing");;
                *)     errors+=("$prefix.source.type '$stype' invalid (git|local)");;
            esac
        fi

        # schedule + entrypoint are optional, but if one is present both must be
        local sched ep
        sched="$(jq -r "$prefix.schedule  // empty" "$config")"
        ep="$(jq -r   "$prefix.entrypoint // empty" "$config")"
        if [[ -n "$sched" && -z "$ep" ]] || [[ -z "$sched" && -n "$ep" ]]; then
            errors+=("$prefix: schedule and entrypoint must both be set (or both omitted)")
        fi
        if [[ -n "$sched" ]]; then
            _validate_cron "$sched" || errors+=("$prefix.schedule '$sched' is not a valid 5-field cron expression")
        fi
        i=$((i+1))
    done

    # Resources
    local cpus mem
    cpus="$(jqget "$config" '.resources.cpus' '')"
    mem="$(jqget  "$config" '.resources.memory' '')"
    [[ -z "$cpus" || "$cpus" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        || errors+=(".resources.cpus '$cpus' must be a number (e.g. \"1.5\")")
    [[ -z "$mem"  || "$mem"  =~ ^[0-9]+[bkmgKMG]?$ ]] \
        || errors+=(".resources.memory '$mem' must look like 512m, 1g, …")

    # Ports
    mapfile -t PORTS < <(jq -r '.network.ports[]?' "$config")
    for p in "${PORTS[@]}"; do
        [[ "$p" =~ ^([0-9.]+:)?[0-9]+:[0-9]+(/(tcp|udp))?$ ]] \
            || errors+=(".network.ports entry '$p' invalid (use HOST:CONTAINER or HOST_IP:HOST:CONTAINER)")
    done

    # Packages
    mapfile -t PKGS < <(jq -r '.packages[]?' "$config")
    for pkg in "${PKGS[@]}"; do
        [[ "$pkg" =~ ^[a-zA-Z0-9._+-]+$ ]] \
            || errors+=(".packages entry '$pkg' invalid")
    done

    if (( ${#errors[@]} > 0 )); then
        err "config validation failed for $config:"
        for e in "${errors[@]}"; do err "  - $e"; done
        return 1
    fi
    return 0
}

# Minimal validator for a 5-field cron expression. Allows */N, ranges, lists,
# and bare numbers. This is good enough to catch typos; the container's cron
# is the source of truth at runtime.
_validate_cron() {
    local expr="$1"
    # Trim whitespace
    expr="$(echo "$expr" | xargs || true)"
    [[ "$expr" =~ ^@(yearly|annually|monthly|weekly|daily|midnight|hourly|reboot)$ ]] && return 0
    local fields; read -r -a fields <<<"$expr"
    [[ ${#fields[@]} -eq 5 ]] || return 1
    local f
    for f in "${fields[@]}"; do
        [[ "$f" =~ ^(\*|[0-9]+)(-[0-9]+)?(/[0-9]+)?(,(\*|[0-9]+)(-[0-9]+)?(/[0-9]+)?)*$ ]] || return 1
    done
    return 0
}

# ---- show / get / set ------------------------------------------------------

show_config() {
    local config="$1/def/config.json"
    [[ -f "$config" ]] || die "no config at $config"
    jq . "$config"
}

get_config() {
    local config="$1/def/config.json"; shift
    local expr="${1:-.}"
    [[ -f "$config" ]] || die "no config at $config"
    jq -r "$expr" "$config"
}

set_config() {
    local deploy_dir="$1" path="$2" value="$3"
    local config="$deploy_dir/def/config.json"
    [[ -f "$config" ]] || die "no config at $config"

    # If the value parses as JSON, treat it as JSON (numbers, booleans, arrays,
    # objects). Otherwise treat it as a string.
    if echo "$value" | jq -e . >/dev/null 2>&1; then
        jq_inplace "$config" --argjson v "$value" "$path = \$v"
    else
        jq_inplace "$config" --arg v "$value" "$path = \$v"
    fi
    validate_config "$deploy_dir"
    info "set $path = $value"
}

edit_config() {
    local deploy_dir="$1"
    local config="$deploy_dir/def/config.json"
    [[ -f "$config" ]] || die "no config at $config"
    local editor="${EDITOR:-${VISUAL:-nano}}"
    local backup; backup="$(mktemp)"
    cp "$config" "$backup"
    "$editor" "$config"
    if ! validate_config "$deploy_dir"; then
        err "config invalid; restoring previous version"
        mv "$backup" "$config"
        return 1
    fi
    rm -f "$backup"
    info "config saved and validated"
}

# ---- app management --------------------------------------------------------

add_app() {
    local deploy_dir="$1"; shift
    local name="" git="" ref="main" local_path="" schedule="" entrypoint=""
    while (( $# > 0 )); do
        case "$1" in
            --name)       name="$2"; shift 2 ;;
            --git)        git="$2"; shift 2 ;;
            --ref)        ref="$2"; shift 2 ;;
            --local)      local_path="$2"; shift 2 ;;
            --schedule)   schedule="$2"; shift 2 ;;
            --entrypoint) entrypoint="$2"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    [[ -n "$name" ]] || die "--name is required"
    [[ -n "$git" || -n "$local_path" ]] || die "one of --git or --local is required"
    [[ -n "$git" && -n "$local_path" ]] && die "use either --git or --local, not both"

    local config="$deploy_dir/def/config.json"
    [[ -f "$config" ]] || die "no config at $config"

    if [[ "$(jq --arg n "$name" '[.apps[] | select(.app_name==$n)] | length' "$config")" -gt 0 ]]; then
        die "app '$name' already exists"
    fi

    local source_json
    if [[ -n "$git" ]]; then
        source_json="$(jq -nc --arg url "$git" --arg ref "$ref" \
            '{type:"git", url:$url, ref:$ref}')"
    else
        source_json="$(jq -nc --arg p "$local_path" '{type:"local", path:$p}')"
    fi

    local app_json
    app_json="$(jq -nc \
        --arg n  "$name" \
        --argjson src "$source_json" \
        --arg sc "$schedule" \
        --arg ep "$entrypoint" \
        '{app_name:$n, source:$src}
         | if $sc != "" then . + {schedule:$sc} else . end
         | if $ep != "" then . + {entrypoint:$ep} else . end')"

    jq_inplace "$config" --argjson app "$app_json" '.apps += [$app]'
    validate_config "$deploy_dir"
    info "added app '$name'"
}

remove_app() {
    local deploy_dir="$1" name="$2"
    local config="$deploy_dir/def/config.json"
    [[ -f "$config" ]] || die "no config at $config"
    if [[ "$(jq --arg n "$name" '[.apps[] | select(.app_name==$n)] | length' "$config")" -eq 0 ]]; then
        die "no such app: $name"
    fi
    jq_inplace "$config" --arg n "$name" '.apps |= map(select(.app_name != $n))'
    info "removed app '$name'"
}

set_schedule() {
    local deploy_dir="$1" name="$2" cron="$3"
    _validate_cron "$cron" || die "invalid cron expression: $cron"
    jq_inplace "$deploy_dir/def/config.json" \
        --arg n "$name" --arg c "$cron" \
        '.apps |= map(if .app_name == $n then .schedule = $c else . end)'
    info "set schedule for $name → $cron"
}

# ---- CLI dispatch (when executed directly) ---------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"; shift || true
    case "$cmd" in
        validate)     validate_config "$@" ;;
        show)         show_config "$@" ;;
        get)          get_config  "$@" ;;
        set)          set_config  "$@" ;;
        edit)         edit_config "$@" ;;
        add-app)      add_app     "$@" ;;
        remove-app)   remove_app  "$@" ;;
        set-schedule) set_schedule "$@" ;;
        *) die "usage: config.sh {validate|show|get|set|edit|add-app|remove-app|set-schedule} ..." ;;
    esac
fi
