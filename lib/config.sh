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
    _check '(.apps | type == "array")' '.apps must be an array'

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

        # Validate the source contents. URLs/refs/paths must not start with '-'
        # (git argument injection), local paths must not be obvious system dirs.
        local sa_url sa_ref sa_path
        sa_url="$(jq -r  "$prefix.source.url  // .apps[$i].git_url  // empty" "$config")"
        sa_ref="$(jq -r  "$prefix.source.ref  // .apps[$i].ref      // .apps[$i].branch // empty" "$config")"
        sa_path="$(jq -r "$prefix.source.path // empty" "$config")"
        case "$sa_url"  in -*) errors+=("$prefix.source.url must not start with '-' (got: $sa_url)");; esac
        case "$sa_ref"  in -*) errors+=("$prefix.source.ref must not start with '-' (got: $sa_ref)");; esac

        if [[ "$(jq "$prefix.source != null" "$config")" == "true" ]]; then
            local stype; stype="$(jq -r "$prefix.source.type" "$config")"
            case "$stype" in
                git)
                    [[ -n "$sa_url" && "$sa_url" != "null" ]] \
                        || errors+=("$prefix.source.url missing")
                    ;;
                local)
                    [[ -n "$sa_path" ]] \
                        || errors+=("$prefix.source.path missing")
                    if [[ -n "$sa_path" ]]; then
                        [[ "$sa_path" == /* ]] \
                            || errors+=("$prefix.source.path must be an absolute path (got: $sa_path)")
                        [[ "$sa_path" == *..* ]] \
                            && errors+=("$prefix.source.path must not contain '..' (got: $sa_path)")
                        # Refuse obvious system dirs unless explicitly opted-in.
                        local _allow_path
                        _allow_path="$(jqget "$config" '.allow_dangerous_paths' 'false')"
                        if [[ "$_allow_path" != "true" ]]; then
                            case "$sa_path" in
                                /|/etc|/etc/*|/root|/root/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/boot|/boot/*|/var/run/docker.sock)
                                    errors+=("$prefix.source.path '$sa_path' is a forbidden system path (set .allow_dangerous_paths=true to override)") ;;
                            esac
                        fi
                    fi
                    ;;
                *) errors+=("$prefix.source.type '$stype' invalid (git|local)") ;;
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
        # Entrypoint is interpolated into the container crontab. Disallow shell
        # metacharacters, '..', and leading '/' (entrypoint is relative to the
        # app's source dir).
        if [[ -n "$ep" ]]; then
            [[ "$ep" =~ ^[A-Za-z0-9_./-]+$ ]] \
                || errors+=("$prefix.entrypoint must match [A-Za-z0-9_./-]+ (got: $ep)")
            [[ "$ep" == /* ]] \
                && errors+=("$prefix.entrypoint must be relative to the app's source dir (got: $ep)")
            [[ "$ep" == *..* ]] \
                && errors+=("$prefix.entrypoint must not contain '..' (got: $ep)")
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

    # Tags
    mapfile -t TAGS < <(jq -r '.tags[]?' "$config")
    for t in "${TAGS[@]}"; do
        [[ "$t" =~ ^[a-zA-Z0-9_-]+$ ]] \
            || errors+=(".tags entry '$t' invalid (use [a-zA-Z0-9_-])")
    done

    # Hooks — must be relative paths confined under deploy_dir. Hooks run on
    # the host with the invoking user's privileges, so this is a security
    # boundary, not just a style guide.
    local hook
    for hook in pre_deploy post_deploy on_failure pre_snapshot post_snapshot; do
        local hp; hp="$(jqget "$config" ".hooks.$hook")"
        [[ -z "$hp" ]] && continue
        if [[ "$hp" == /* ]]; then
            errors+=(".hooks.$hook must be a path relative to the deployment dir (got: $hp)")
            continue
        fi
        if [[ "$hp" == *..* ]]; then
            errors+=(".hooks.$hook must not contain '..' (got: $hp)")
            continue
        fi
        local resolved; resolved="$(realpath -m -- "$deploy_dir/$hp" 2>/dev/null || true)"
        case "$resolved" in
            "$deploy_dir"/*) : ;;
            *) errors+=(".hooks.$hook escapes the deployment dir: $hp → $resolved") ; continue ;;
        esac
        [[ -f "$resolved" ]] || errors+=(".hooks.$hook points at missing file: $hp")
    done

    # Volumes — config-supplied -v entries. Block mounting obvious host
    # secrets / system paths unless allow_dangerous_volumes is set.
    local _allow_vol
    _allow_vol="$(jqget "$config" '.allow_dangerous_volumes' 'false')"
    mapfile -t _VOLS < <(jq -r '.volumes[]?' "$config")
    for v in "${_VOLS[@]}"; do
        # docker -v supports HOST:CONTAINER and HOST:CONTAINER:MODE
        if [[ ! "$v" =~ ^[A-Za-z0-9_./-]+:/[A-Za-z0-9_./-]+(:(ro|rw|z|Z|ro,Z|rw,Z))?$ ]]; then
            errors+=(".volumes entry '$v' invalid (expected HOST_PATH:CONTAINER_PATH[:mode])")
            continue
        fi
        local host_side="${v%%:*}"
        # Reject anything containing '..' or not absolute.
        if [[ "$host_side" != /* ]]; then
            errors+=(".volumes host side '$host_side' must be an absolute path")
            continue
        fi
        if [[ "$host_side" == *..* ]]; then
            errors+=(".volumes host side '$host_side' must not contain '..'")
            continue
        fi
        if [[ "$_allow_vol" != "true" ]]; then
            case "$host_side" in
                /|/etc|/etc/*|/root|/root/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/boot|/boot/*|/var/run/docker.sock|/var/lib/docker|/var/lib/docker/*)
                    errors+=(".volumes host side '$host_side' is forbidden (set .allow_dangerous_volumes=true to override)") ;;
            esac
        fi
    done

    # backup.skip_volumes — host paths that `nelly snapshot` should NOT
    # quiesce-tar (because hooks.pre_snapshot covers them with a logical
    # dump). Each must be an absolute path with no '..' — same rules as
    # .volumes host-side validation.
    if [[ "$(jq '.backup.skip_volumes != null' "$config")" == "true" ]]; then
        [[ "$(jq '.backup.skip_volumes | type' "$config")" == '"array"' ]] \
            || errors+=(".backup.skip_volumes must be an array of host paths")
        mapfile -t _SKIPVOLS < <(jq -r '.backup.skip_volumes[]?' "$config")
        for sv in "${_SKIPVOLS[@]}"; do
            [[ "$sv" == /* ]]    || errors+=(".backup.skip_volumes entry '$sv' must be an absolute path")
            [[ "$sv" == *..* ]] && errors+=(".backup.skip_volumes entry '$sv' must not contain '..'")
        done
    fi

    # Extra networks: each must be a string
    mapfile -t XNETS < <(jq -r '.network.extra_networks[]?' "$config")
    for n in "${XNETS[@]}"; do
        [[ "$n" =~ ^[a-zA-Z0-9._-]+$ ]] \
            || errors+=(".network.extra_networks entry '$n' invalid")
    done

    # base_image — must not start with '-' (docker arg injection); must be a
    # plausible image reference. Encourage digest pinning by warning when no
    # @sha256 is present (warning, not error).
    local bimg
    bimg="$(jqget "$config" '.base_image' '')"
    if [[ -n "$bimg" ]]; then
        case "$bimg" in -*) errors+=(".base_image must not start with '-' (got: $bimg)");; esac
        [[ "$bimg" =~ ^[a-zA-Z0-9][a-zA-Z0-9_./:@-]*$ ]] \
            || errors+=(".base_image '$bimg' is not a valid image reference")
    fi

    # Healthcheck duration fields — docker accepts Ns / Nm / Nh / Nms.
    local hcfield hcval
    for hcfield in interval timeout start_period; do
        hcval="$(jqget "$config" ".health.$hcfield" '')"
        if [[ -n "$hcval" ]] && ! [[ "$hcval" =~ ^[0-9]+(ns|us|ms|s|m|h)$ ]]; then
            errors+=(".health.$hcfield '$hcval' must look like '30s', '500ms', '1m', …")
        fi
    done
    local hcretries
    hcretries="$(jqget "$config" '.health.retries' '')"
    if [[ -n "$hcretries" ]] && ! [[ "$hcretries" =~ ^[0-9]+$ ]]; then
        errors+=(".health.retries '$hcretries' must be a non-negative integer")
    fi
    # .health.cmd is the one config field that reaches a shell — docker runs it
    # via `/bin/sh -c` inside the container. A custom one is therefore gated
    # behind an explicit opt-in (mirrors allow_dangerous_volumes/_paths); the
    # default healthcheck (applied by run.sh when .health.cmd is empty) is fine.
    local hccmd _allow_hc
    hccmd="$(jqget "$config" '.health.cmd' '')"
    _allow_hc="$(jqget "$config" '.allow_dangerous_health_cmd' 'false')"
    if [[ -n "$hccmd" && "$_allow_hc" != "true" ]]; then
        errors+=(".health.cmd runs a shell command inside the container; set .allow_dangerous_health_cmd=true to use a custom one (the default cron healthcheck needs no opt-in)")
    fi

    # .log_retention_days feeds `find -mtime "+N"`; must be a plain integer or
    # pruning silently breaks (it is quoted, so this is correctness not injection).
    local lrd
    lrd="$(jqget "$config" '.log_retention_days' '')"
    if [[ -n "$lrd" ]] && ! [[ "$lrd" =~ ^[0-9]+$ ]]; then
        errors+=(".log_retention_days '$lrd' must be a non-negative integer")
    fi

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

    # Snapshot, write, validate; restore on failure so a bad value never lands.
    local backup; backup="$(mktemp)"
    cp "$config" "$backup"

    if echo "$value" | jq -e . >/dev/null 2>&1; then
        jq_inplace "$config" --argjson v "$value" "$path = \$v"
    else
        jq_inplace "$config" --arg v "$value" "$path = \$v"
    fi
    if ! validate_config "$deploy_dir" 2>&1; then
        mv "$backup" "$config"
        die "rejected: $path = $value (config was not modified)"
    fi
    rm -f "$backup"
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

    local backup; backup="$(mktemp)"
    cp "$config" "$backup"
    jq_inplace "$config" --argjson app "$app_json" '.apps += [$app]'
    if ! validate_config "$deploy_dir" 2>&1; then
        mv "$backup" "$config"
        die "rejected: app '$name' (config was not modified)"
    fi
    rm -f "$backup"
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

# ---- tags ------------------------------------------------------------------

list_tags() {
    local deploy_dir="$1"
    jq -r '(.tags // []) | .[]' "$deploy_dir/def/config.json"
}

add_tags() {
    local deploy_dir="$1"; shift
    (( $# > 0 )) || die "usage: tag add <name> TAG [TAG...]"
    for t in "$@"; do
        [[ "$t" =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid tag: $t (use [a-zA-Z0-9_-])"
    done
    local config="$deploy_dir/def/config.json"
    jq_inplace "$config" --argjson new "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
        '.tags = ((.tags // []) + $new | unique)'
    info "tags: $(jq -r '(.tags // []) | join(", ")' "$config")"
}

remove_tags() {
    local deploy_dir="$1"; shift
    (( $# > 0 )) || die "usage: tag remove <name> TAG [TAG...]"
    local config="$deploy_dir/def/config.json"
    jq_inplace "$config" --argjson rm "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
        '.tags = ((.tags // []) - $rm)'
    info "tags: $(jq -r '(.tags // []) | join(", ")' "$config")"
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
        tags-list)    list_tags   "$@" ;;
        tags-add)     add_tags    "$@" ;;
        tags-remove)  remove_tags "$@" ;;
        *) die "usage: config.sh {validate|show|get|set|edit|add-app|remove-app|set-schedule|tags-list|tags-add|tags-remove} ..." ;;
    esac
fi
