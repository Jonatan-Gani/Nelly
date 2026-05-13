#!/usr/bin/env bash
# lib/source.sh — fetch an app's source into a target directory.
#
# Two source types are supported:
#   { "type": "git",   "url": "...", "ref": "main" }
#   { "type": "local", "path": "/absolute/path" }
#
# Backwards-compatible: an app with legacy top-level git_url/ref/branch
# fields is treated as { type: "git", url: git_url, ref: ref|branch }.
#
# Stdout (when invoked as a subprocess): a single line containing the
# resolved revision id (git SHA, or "local:<mtime>" for local sources).

set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

# normalize_app_source <app-json> → echoes a normalized json object
normalize_app_source() {
    local app="$1"
    echo "$app" | jq -c '
        if .source then .source
        elif .git_url then { type: "git", url: .git_url, ref: (.ref // .branch // "main") }
        else error("app has no source: define apps[].source or apps[].git_url")
        end
    '
}

# fetch_source <app-json> <target_dir> — populates target_dir, prints revision.
fetch_source() {
    local app="$1" target="$2"
    local src; src="$(normalize_app_source "$app")"
    local type; type="$(echo "$src" | jq -r '.type')"

    rm -rf "$target"
    mkdir -p "$target"

    case "$type" in
        git)
            local url ref
            url="$(echo "$src" | jq -r '.url')"
            ref="$(echo "$src" | jq -r '.ref // "main"')"
            [[ -n "$url" && "$url" != "null" ]] || die "git source missing url"
            _fetch_git "$url" "$ref" "$target"
            ;;
        local)
            local path
            path="$(echo "$src" | jq -r '.path')"
            [[ -n "$path" && "$path" != "null" ]] || die "local source missing path"
            _fetch_local "$path" "$target"
            ;;
        *)
            die "unknown source type: $type (supported: git, local)"
            ;;
    esac
}

_fetch_git() {
    local url="$1" ref="$2" target="$3"
    require_cmd git rsync
    local tmp; tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    # Try a shallow clone of the ref first; fall back to a full clone + checkout
    # so commit SHAs and tags work too.
    if ! git clone --quiet --depth 50 --branch "$ref" "$url" "$tmp" 2>/dev/null; then
        git clone --quiet "$url" "$tmp"
        ( cd "$tmp" && git checkout --quiet "$ref" )
    fi

    local sha; sha="$(cd "$tmp" && git rev-parse HEAD)"
    rsync -a --delete --exclude='.git' "$tmp/" "$target/"
    echo "$sha"
}

_fetch_local() {
    local path="$1" target="$2"
    require_cmd rsync
    [[ -d "$path" ]] || die "local source path not found: $path"
    # Resolve to absolute path so behaviour is consistent regardless of CWD.
    path="$(cd "$path" && pwd)"

    # If the local path is itself a git working copy, record its HEAD; otherwise
    # fall back to a deterministic content hash of file mtimes.
    local rev
    if [[ -d "$path/.git" ]] && command -v git >/dev/null 2>&1; then
        rev="$(cd "$path" && git rev-parse HEAD 2>/dev/null || true)"
        [[ -n "$rev" ]] || rev="local:$(date +%s)"
    else
        rev="local:$(find "$path" -type f -not -path '*/.git/*' -printf '%T@ %p\n' 2>/dev/null \
                     | sort | sha256sum | cut -c1-12)"
    fi

    rsync -a --delete \
        --exclude='.git' --exclude='__pycache__' --exclude='.venv' --exclude='node_modules' \
        "$path/" "$target/"
    echo "$rev"
}

# When sourced, do nothing. When executed directly with `fetch_source ARGS`,
# behave as a CLI for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        fetch_source) shift; fetch_source "$@" ;;
        normalize)    shift; normalize_app_source "$@" ;;
        *) die "usage: source.sh fetch_source <app-json> <target> | normalize <app-json>" ;;
    esac
fi
