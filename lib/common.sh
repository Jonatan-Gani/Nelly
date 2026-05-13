# Shared bash helpers. Source me; do not execute.
# Expects callers to have set -euo pipefail.

ts()   { date +"%Y-%m-%d %H:%M:%S"; }
info() { printf '%s [INFO]  %s\n' "$(ts)" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

# log_to <file> — pipe stdout+stderr of caller into both terminal and file.
# Usage: exec > >(log_to "$LOG_FILE") 2>&1
log_to() {
    local f="$1"
    mkdir -p "$(dirname "$f")"
    tee -a "$f"
}

# confirm "<prompt>" — returns 0 if user says yes, or if INTERACTIVE=0.
confirm() {
    if [[ "${INTERACTIVE:-0}" != "1" ]]; then
        return 0
    fi
    local prompt="${1:-Continue?}"
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[yY] ]]
}

# jqget <file> <jq-expr> [default] — read a value or fall back.
jqget() {
    local file="$1" expr="$2" default="${3:-}"
    local v
    v="$(jq -r "$expr // empty" "$file")"
    if [[ -z "$v" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$v"
    fi
}
