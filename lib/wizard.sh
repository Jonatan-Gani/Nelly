#!/usr/bin/env bash
# lib/wizard.sh — small interactive helpers and the multi-step setup wizards.
#
# All prompts respect NELLY_YES=1 (auto-accept defaults, fail on missing
# required values) so wizards can also drive non-interactive flows.

set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

# -----------------------------------------------------------------------------
# Low-level prompt helpers
# -----------------------------------------------------------------------------

_bold() {
    [[ -t 1 ]] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"
}
_dim() {
    [[ -t 1 ]] && printf '\033[2m%s\033[0m' "$1" || printf '%s' "$1"
}

# prompt_required <prompt> <var-name> [validator-fn]
prompt_required() {
    local prompt="$1" var="$2" validate="${3:-}"
    local val
    while true; do
        if [[ "${NELLY_YES:-0}" == "1" ]]; then
            die "missing required value for: $prompt (running non-interactively)"
        fi
        printf '%s ' "$(_bold "$prompt")" >&2
        IFS= read -r val
        if [[ -z "$val" ]]; then
            echo "  (required — please enter a value)" >&2
            continue
        fi
        if [[ -n "$validate" ]] && ! "$validate" "$val"; then
            continue
        fi
        printf -v "$var" '%s' "$val"
        return 0
    done
}

# prompt_default <prompt> <default> <var-name> [validator-fn]
prompt_default() {
    local prompt="$1" default="$2" var="$3" validate="${4:-}"
    local val
    while true; do
        if [[ "${NELLY_YES:-0}" == "1" ]]; then
            val="$default"
        else
            printf '%s %s ' "$(_bold "$prompt")" "$(_dim "[$default]")" >&2
            IFS= read -r val
            [[ -z "$val" ]] && val="$default"
        fi
        if [[ -n "$validate" ]] && ! "$validate" "$val"; then
            continue
        fi
        printf -v "$var" '%s' "$val"
        return 0
    done
}

# prompt_yes_no <prompt> <default y|n> → returns 0/1
prompt_yes_no() {
    local prompt="$1" default="${2:-n}" ans
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    if [[ "${NELLY_YES:-0}" == "1" ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    printf '%s %s ' "$(_bold "$prompt")" "$(_dim "$hint")" >&2
    IFS= read -r ans
    [[ -z "$ans" ]] && ans="$default"
    [[ "$ans" =~ ^[yY] ]]
}

# prompt_choice <prompt> <var-name> <option1> <option2> ...
prompt_choice() {
    local prompt="$1" var="$2"; shift 2
    local -a opts=("$@")
    local i=1 sel
    while true; do
        printf '%s\n' "$(_bold "$prompt")" >&2
        i=1
        for o in "${opts[@]}"; do
            printf '  %d) %s\n' "$i" "$o" >&2
            i=$((i+1))
        done
        if [[ "${NELLY_YES:-0}" == "1" ]]; then
            sel=1
        else
            printf '%s ' "$(_dim '[1]')" >&2
            IFS= read -r sel
            [[ -z "$sel" ]] && sel=1
        fi
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#opts[@]} )); then
            printf -v "$var" '%s' "${opts[$((sel-1))]}"
            return 0
        fi
        echo "  (please enter a number between 1 and ${#opts[@]})" >&2
    done
}

# -----------------------------------------------------------------------------
# Validators (used by the prompts above)
# -----------------------------------------------------------------------------

_v_deployment_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] && return 0
    echo "  → must match [a-zA-Z0-9_-]+ (got: '$1')" >&2; return 1
}
_v_container_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]] && return 0
    echo "  → must start with a letter or digit, then [a-zA-Z0-9_.-] (got: '$1')" >&2; return 1
}
_v_image_name() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] && return 0
    echo "  → must be lowercase letters/digits with [._-] (got: '$1')" >&2; return 1
}
_v_app_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] && return 0
    echo "  → must match [a-zA-Z0-9_-]+ (got: '$1')" >&2; return 1
}
_v_cron() {
    _validate_cron "$1" && return 0
    echo "  → not a valid 5-field cron expression (e.g. '*/5 * * * *', '0 9 * * *', '@daily')" >&2; return 1
}
_v_nonempty() {
    [[ -n "$1" ]] && return 0
    echo "  → required" >&2; return 1
}
_v_existing_dir() {
    [[ -d "$1" ]] && return 0
    echo "  → no such directory: $1" >&2; return 1
}

# -----------------------------------------------------------------------------
# Setup wizard — runs after `nelly init`
# -----------------------------------------------------------------------------

# wizard_init <deploy_dir>
wizard_init() {
    local deploy_dir="$1"
    local name; name="$(basename "$deploy_dir")"

    cat >&2 <<EOF

$(_bold "Setting up deployment '$name'")
$(_dim "Press Enter to accept the default in [brackets]. Ctrl-C to abort.")

EOF

    local container image
    prompt_default "Container name?" "$name" container _v_container_name
    prompt_default "Image name?"     "${name,,}" image _v_image_name

    "$LIB/config.sh" set "$deploy_dir" '.container_name' "$container" >/dev/null
    "$LIB/config.sh" set "$deploy_dir" '.image_name'     "$image"     >/dev/null

    # Strip the placeholder app from the template's config — we'll add a real one (or none).
    jq_inplace "$deploy_dir/def/config.json" '.apps = []'

    # Skip optional steps when running non-interactively; the caller can always
    # invoke `nelly app add` / `nelly secrets set` afterwards.
    if [[ "${NELLY_YES:-0}" != "1" ]]; then
        echo >&2
        if prompt_yes_no "Add an app now?" y; then
            wizard_add_app "$deploy_dir"
        fi

        echo >&2
        if prompt_yes_no "Add secrets now (DB passwords, API keys, …)?" n; then
            wizard_add_secrets "$deploy_dir"
        fi
    fi

    cat >&2 <<EOF

$(_bold "Done.") Deployment scaffolded at: $deploy_dir

Next steps:
  $(_bold "nelly explain $name")   $(_dim "# preview what this deployment will do")
  $(_bold "nelly doctor  $name")   $(_dim "# sanity-check before deploying")
  $(_bold "nelly deploy  $name")   $(_dim "# fetch, build, and start")

You can also edit the config file directly:
  $(_dim "  \$EDITOR $deploy_dir/def/config.json")
  $(_bold "nelly edit $name")      $(_dim "# opens \$EDITOR; validates on save")

EOF
}

# -----------------------------------------------------------------------------
# Add-app wizard — runs from `nelly app add <name>` when flags are missing
# -----------------------------------------------------------------------------

wizard_add_app() {
    local deploy_dir="$1"
    local app_name source_type git_url git_ref local_path schedule entrypoint
    local config="$deploy_dir/def/config.json"

    cat >&2 <<EOF

$(_bold "Adding an app to '$(basename "$deploy_dir")'")
$(_dim "An app = one Python script that Nelly will run on a schedule.")

EOF

    prompt_required "App name (e.g. 'scraper', 'digest')?" app_name _v_app_name

    # Avoid duplicates
    if (( $(jq --arg n "$app_name" '[.apps[] | select(.app_name==$n)] | length' "$config") > 0 )); then
        die "app '$app_name' already exists in this deployment"
    fi

    echo >&2
    prompt_choice "Where does the code come from?" source_type \
        "Git repository (clone at a ref)" \
        "Local directory (rsync from a path on this host)"

    case "$source_type" in
        Git*)
            prompt_required "Git URL (e.g. git@github.com:me/repo.git)?" git_url _v_nonempty
            prompt_default  "Branch / tag / commit SHA?" "main" git_ref _v_nonempty
            ;;
        Local*)
            prompt_required "Path on this host?" local_path _v_existing_dir
            ;;
    esac

    echo >&2
    echo "$(_bold 'When should it run?')" >&2
    echo "$(_dim '  Examples:  */5 * * * *   every 5 min')" >&2
    echo "$(_dim '             0 9 * * *     daily at 09:00')" >&2
    echo "$(_dim '             @hourly       every hour')" >&2
    prompt_default "Cron schedule?" "*/5 * * * *" schedule _v_cron

    echo >&2
    prompt_default "Entry point (Python file inside the repo)?" "main.py" entrypoint _v_nonempty

    # Show the proposed entry as JSON before writing
    local proposed
    if [[ -n "${git_url:-}" ]]; then
        proposed="$(jq -nc \
            --arg n "$app_name" --arg url "$git_url" --arg ref "$git_ref" \
            --arg sc "$schedule" --arg ep "$entrypoint" \
            '{app_name:$n, source:{type:"git", url:$url, ref:$ref}, schedule:$sc, entrypoint:$ep}')"
    else
        proposed="$(jq -nc \
            --arg n "$app_name" --arg p "$local_path" \
            --arg sc "$schedule" --arg ep "$entrypoint" \
            '{app_name:$n, source:{type:"local", path:$p}, schedule:$sc, entrypoint:$ep}')"
    fi

    cat >&2 <<EOF

$(_bold "About to add this app:")
$(echo "$proposed" | jq .)

EOF
    if ! prompt_yes_no "Looks good?" y; then
        info "cancelled — no changes made"
        return 0
    fi

    jq_inplace "$config" --argjson app "$proposed" '.apps += [$app]'
    validate_config "$deploy_dir"
    info "added app '$app_name'"
}

# -----------------------------------------------------------------------------
# Secrets wizard
# -----------------------------------------------------------------------------

wizard_add_secrets() {
    local deploy_dir="$1"
    local key value

    cat >&2 <<EOF

$(_bold "Adding secrets")
$(_dim "These go into def/.env (file mode 0600) and are mounted into the")
$(_dim "container at runtime via --env-file. They are never baked into the image.")
$(_dim "Type an empty key to stop.")

EOF

    while true; do
        printf '%s ' "$(_bold 'Key name (or Enter to stop)?')" >&2
        IFS= read -r key
        [[ -z "$key" ]] && break
        if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "  → invalid key name; use letters/digits/underscores" >&2
            continue
        fi
        printf '%s ' "$(_bold "Value for $key (hidden)?")" >&2
        IFS= read -r -s value; echo >&2
        "$LIB/secrets.sh" set "$deploy_dir" "$key=$value" >/dev/null
    done
}

# -----------------------------------------------------------------------------
# CLI dispatch (when invoked directly — used by bin/nelly)
# -----------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"; shift || true
    case "$cmd" in
        init)        wizard_init     "$@" ;;
        add-app)     wizard_add_app  "$@" ;;
        add-secrets) wizard_add_secrets "$@" ;;
        *) die "usage: wizard.sh {init|add-app|add-secrets} <deploy_dir>" ;;
    esac
fi
