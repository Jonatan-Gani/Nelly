#!/usr/bin/env bash
# lib/secrets.sh — manage def/.env, with file perms locked down.
#
# Subcommands: set | unset | list | edit | template
set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

sub="${1:-}"; shift || true
DEPLOY_DIR="${1:-}"; shift || true
[[ -n "$sub" && -n "$DEPLOY_DIR" ]] || die "usage: secrets.sh {set|unset|list|edit|template} <deploy_dir> [args...]"

ENV_FILE="$DEPLOY_DIR/def/.env"
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

_valid_key() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

case "$sub" in
    set)
        # nelly secrets set <dir> KEY=value [KEY2=value2 ...]
        # Or: nelly secrets set <dir> KEY -  (reads value from stdin, no echo)
        (( $# > 0 )) || die "usage: secrets set <dir> KEY=value [KEY=value ...]"
        for pair in "$@"; do
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
            # Drop any existing line for this key, then append.
            tmp="$(mktemp)"
            grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
            # Escape backslashes and double quotes in the value.
            esc="${value//\\/\\\\}"; esc="${esc//\"/\\\"}"
            printf '%s="%s"\n' "$key" "$esc" >> "$tmp"
            mv "$tmp" "$ENV_FILE"
            chmod 600 "$ENV_FILE"
            info "set $key"
        done
        ;;
    unset)
        (( $# > 0 )) || die "usage: secrets unset <dir> KEY [KEY ...]"
        for key in "$@"; do
            _valid_key "$key" || die "invalid key: $key"
            tmp="$(mktemp)"
            grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
            mv "$tmp" "$ENV_FILE"
            chmod 600 "$ENV_FILE"
            info "unset $key"
        done
        ;;
    list)
        # Print keys only (never values).
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
            awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$ENV_FILE" \
                | jq -R . | jq -s .
        else
            awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ {print $1}' "$ENV_FILE"
        fi
        ;;
    edit)
        editor="${EDITOR:-${VISUAL:-nano}}"
        backup="$(mktemp)"
        cp "$ENV_FILE" "$backup"
        "$editor" "$ENV_FILE"
        # Basic validation: every non-blank, non-comment line must look like KEY=...
        if grep -Ev '^\s*(#|$)' "$ENV_FILE" | grep -Ev '^[A-Za-z_][A-Za-z0-9_]*=' >/dev/null; then
            err "invalid .env content; restoring previous version"
            mv "$backup" "$ENV_FILE"
            exit 1
        fi
        chmod 600 "$ENV_FILE"
        rm -f "$backup"
        ;;
    template)
        # Print a template based on config.json apps[].env references (legacy).
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
