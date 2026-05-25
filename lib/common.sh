# lib/common.sh — shared bash helpers. Source me; do not execute.
# shellcheck shell=bash
# Callers must set: set -euo pipefail

# ---- logging ---------------------------------------------------------------

_nelly_color() {
    [[ -t 2 ]] || { printf '%s' "$2"; return; }
    case "$1" in
        red)    printf '\033[31m%s\033[0m' "$2" ;;
        yellow) printf '\033[33m%s\033[0m' "$2" ;;
        green)  printf '\033[32m%s\033[0m' "$2" ;;
        dim)    printf '\033[2m%s\033[0m'  "$2" ;;
        *)      printf '%s' "$2" ;;
    esac
}

ts()   { date +"%Y-%m-%dT%H:%M:%S%z"; }
info() { printf '%s %s %s\n' "$(_nelly_color dim "$(ts)")" "$(_nelly_color green '[INFO]')"  "$*" >&2; }
warn() { printf '%s %s %s\n' "$(_nelly_color dim "$(ts)")" "$(_nelly_color yellow '[WARN]')" "$*" >&2; }
err()  { printf '%s %s %s\n' "$(_nelly_color dim "$(ts)")" "$(_nelly_color red '[ERROR]')"  "$*" >&2; }
die()  { err "$*"; exit 1; }

# Tee stdout/stderr into a file while preserving the terminal.
log_to() {
    local f="$1"
    mkdir -p "$(dirname "$f")"
    tee -a "$f"
}

# ---- prerequisites ---------------------------------------------------------

require_cmd() {
    local missing=()
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} > 0 )); then
        die "missing required commands: ${missing[*]}"
    fi
}

# ---- interactive prompts ---------------------------------------------------

# confirm "<prompt>" — returns 0 if INTERACTIVE=0 or user says yes.
confirm() {
    if [[ "${NELLY_YES:-0}" == "1" ]]; then return 0; fi
    if [[ "${INTERACTIVE:-0}" != "1" ]]; then return 0; fi
    local prompt="${1:-Continue?}" ans
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[yY] ]]
}

# ---- config helpers --------------------------------------------------------

# jqget <file> <jq-expr> [default]
jqget() {
    local file="$1" expr="$2" default="${3:-}"
    local v
    v="$(jq -r "$expr // empty" "$file" 2>/dev/null || true)"
    if [[ -z "$v" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$v"
    fi
}

# Atomically replace a file using jq.
# Usage: jq_inplace <file> <jq-expr> [--arg ...]
jq_inplace() {
    local file="$1"; shift
    local tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    if jq "$@" "$file" > "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        die "failed to update $file"
    fi
}

# ---- locking ---------------------------------------------------------------

# with_lock <deploy_dir> <command...> — serialize per deployment.
with_lock() {
    local deploy_dir="$1"; shift
    local lockfile="$deploy_dir/.nelly.lock"
    mkdir -p "$deploy_dir"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lockfile"
        if ! flock -n 9; then
            warn "another nelly run is in progress on $deploy_dir; waiting..."
            flock 9
        fi
        "$@"
        local rc=$?
        exec 9>&-
        return $rc
    else
        "$@"
    fi
}

# ---- output formatting -----------------------------------------------------

# Emit either a human table or JSON depending on NELLY_OUTPUT.
emit_json() {
    if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
        cat
    else
        return 0
    fi
}
emit_human() {
    if [[ "${NELLY_OUTPUT:-human}" != "json" ]]; then
        cat
    fi
}

# ---- paths -----------------------------------------------------------------

deployment_dir() {
    local name="$1"
    printf '%s' "${NELLY_ROOT:?NELLY_ROOT not set}/containers/$name"
}

list_deployments() {
    local d
    [[ -d "${NELLY_ROOT}/containers" ]] || return 0
    for d in "${NELLY_ROOT}/containers"/*/; do
        [[ -f "$d/def/config.json" ]] || continue
        basename "${d%/}"
    done
}

# ---- container name helper -------------------------------------------------

container_name_for() {
    local deploy_dir="$1"
    jqget "$deploy_dir/def/config.json" '.container_name' "$(basename "$deploy_dir")"
}
