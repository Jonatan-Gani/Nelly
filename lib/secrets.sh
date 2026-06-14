#!/usr/bin/env bash
# lib/secrets.sh — manage deployment + per-app secrets.
#
# Layout:
#   def/.env                       deployment-wide secrets (mounted via --env-file)
#   def/secrets/<app>.env          per-app secrets (bind-mounted into the
#                                   container as /etc/nelly/secrets/<app>.env
#                                   and sourced by nelly-run only for that app)
#
# This means cron jobs for different apps in the same container do NOT see
# each other's env vars. (They could still read the files if running as root
# inside the container — for full filesystem isolation, run one app per
# deployment.)
#
# Subcommands: set | unset | list | edit | template
#
# All write commands accept `--app <app>` to target a per-app file. Without
# --app, the deployment-wide def/.env is used (existing behavior, backward
# compatible).

set -euo pipefail
LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[[ "$(type -t info)" == "function" ]] || source "$LIB/common.sh"

sub="${1:-}"; shift || true
DEPLOY_DIR="${1:-}"; shift || true
[[ -n "$sub" && -n "$DEPLOY_DIR" ]] || die "usage: secrets.sh {set|unset|list|edit|template} <deploy_dir> [args]"

GLOBAL_ENV="$DEPLOY_DIR/def/.env"
APP_SECRETS_DIR="$DEPLOY_DIR/def/secrets"

# Validate an app name against the deployment's config (defense in depth).
_known_app() {
    local app="$1"
    local cfg="$DEPLOY_DIR/def/config.json"
    [[ -f "$cfg" ]] || return 1
    [[ "$(jq -r --arg n "$app" '[.apps[] | select(.app_name == $n)] | length' "$cfg")" -gt 0 ]]
}

_valid_key() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Resolve the target .env path from optional `--app <name>` in the args.
# Mutates the global $REMAINING_ARGS bash array with the non-flag args.
declare -a REMAINING_ARGS=()
_resolve_target() {
    REMAINING_ARGS=()
    local app=""
    while (( $# > 0 )); do
        case "$1" in
            --app)
                app="${2:-}"; shift 2
                [[ -n "$app" ]] || die "--app requires an app name"
                _known_app "$app" \
                    || warn "app '$app' is not in this deployment's config (writing the file anyway)"
                [[ "$app" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid app name: $app"
                ;;
            *) REMAINING_ARGS+=("$1"); shift ;;
        esac
    done
    if [[ -n "$app" ]]; then
        mkdir -p "$APP_SECRETS_DIR"
        chmod 700 "$APP_SECRETS_DIR"
        TARGET_FILE="$APP_SECRETS_DIR/$app.env"
        TARGET_SCOPE="app:$app"
    else
        TARGET_FILE="$GLOBAL_ENV"
        TARGET_SCOPE="global"
    fi
    touch "$TARGET_FILE"
    chmod 600 "$TARGET_FILE"
}

case "$sub" in

    set)
        # nelly secrets set <dir> [--app A] KEY=value [KEY=value ...]
        # nelly secrets set <dir> [--app A] KEY  (reads value from stdin / prompt)
        _resolve_target "$@"
        (( ${#REMAINING_ARGS[@]} > 0 )) || die "usage: secrets set <dir> [--app A] KEY=value [...]"
        for pair in "${REMAINING_ARGS[@]}"; do
            if [[ "$pair" == *=* ]]; then
                key="${pair%%=*}"; value="${pair#*=}"
            else
                key="$pair"
                if [[ -t 0 ]]; then
                    read -r -s -p "value for $key: " value; echo
                else
                    IFS= read -r value
                fi
            fi
            _valid_key "$key" || die "invalid key: $key"
            tmp="$(mktemp)"
            grep -v "^${key}=" "$TARGET_FILE" > "$tmp" || true
            esc="${value//\\/\\\\}"; esc="${esc//\"/\\\"}"
            printf '%s="%s"\n' "$key" "$esc" >> "$tmp"
            mv "$tmp" "$TARGET_FILE"
            chmod 600 "$TARGET_FILE"
            info "set $key  ($TARGET_SCOPE)"
        done
        ;;

    unset)
        _resolve_target "$@"
        (( ${#REMAINING_ARGS[@]} > 0 )) || die "usage: secrets unset <dir> [--app A] KEY [...]"
        [[ -f "$TARGET_FILE" ]] || die "no such file: $TARGET_FILE"
        for key in "${REMAINING_ARGS[@]}"; do
            _valid_key "$key" || die "invalid key: $key"
            tmp="$(mktemp)"
            grep -v "^${key}=" "$TARGET_FILE" > "$tmp" || true
            mv "$tmp" "$TARGET_FILE"
            chmod 600 "$TARGET_FILE"
            info "unset $key  ($TARGET_SCOPE)"
        done
        ;;

    list)
        # nelly secrets list <dir> [--app A]
        _resolve_target "$@"
        # Special case: list without --app shows ALL scopes (global + every per-app file)
        if [[ "$TARGET_SCOPE" == "global" && "${#REMAINING_ARGS[@]}" -eq 0 ]]; then
            # Build a JSON object of {scope: [keys]}
            json='{}'
            if [[ -f "$GLOBAL_ENV" ]]; then
                gkeys="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$GLOBAL_ENV" | jq -R . | jq -s .)"
                json="$(echo "$json" | jq --argjson k "$gkeys" '.global = $k')"
            fi
            if [[ -d "$APP_SECRETS_DIR" ]]; then
                for f in "$APP_SECRETS_DIR"/*.env; do
                    [[ -f "$f" ]] || continue
                    app="$(basename "$f" .env)"
                    akeys="$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$f" | jq -R . | jq -s .)"
                    json="$(echo "$json" | jq --arg a "$app" --argjson k "$akeys" '.apps[$a] = $k')"
                done
            fi
            if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
                echo "$json"
            else
                global_n="$(echo "$json" | jq -r '.global // [] | length')"
                if (( global_n > 0 )); then
                    echo "global ($global_n key(s)):"
                    echo "$json" | jq -r '.global[]?' | sed 's/^/  /'
                fi
                echo "$json" | jq -r '(.apps // {}) | to_entries[] | "\(.key)\t\(.value | length)"' \
                    | while IFS=$'\t' read -r app n; do
                        echo "app:$app ($n key(s)):"
                        echo "$json" | jq -r --arg a "$app" '.apps[$a][]' | sed 's/^/  /'
                    done
            fi
            exit 0
        fi
        # --app form: just this file's keys
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
            awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$TARGET_FILE" | jq -R . | jq -s .
        else
            awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$TARGET_FILE"
        fi
        ;;

    edit)
        _resolve_target "$@"
        editor="${EDITOR:-${VISUAL:-nano}}"
        backup="$(mktemp)"
        cp "$TARGET_FILE" "$backup"
        "$editor" "$TARGET_FILE"
        if grep -Ev '^\s*(#|$)' "$TARGET_FILE" | grep -Ev '^[A-Za-z_][A-Za-z0-9_]*=' >/dev/null; then
            err "invalid .env content; restoring previous version"
            mv "$backup" "$TARGET_FILE"
            exit 1
        fi
        chmod 600 "$TARGET_FILE"
        rm -f "$backup"
        ;;

    template)
        # Print a skeleton from config.json legacy `env:` references (deployment-wide only).
        config="$DEPLOY_DIR/def/config.json"
        [[ -f "$config" ]] || die "no config"
        jq -r '
            .apps[] | (.env // {}) | to_entries[]
            | select(.value | type == "string" and startswith("ENV_"))
            | "\(.value)="
        ' "$config" | sort -u
        ;;

    *)
        die "unknown sub: $sub" ;;
esac
