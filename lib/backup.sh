#!/usr/bin/env bash
# lib/backup.sh — tarball backup + restore for a deployment.
#
#   backup  <deploy_dir> [--out PATH] [--include-logs]
#       Defaults to writing <name>-<UTC-timestamp>.tar.gz in the current dir.
#       Excludes apps/ (re-fetched on deploy) and logs/ (re-create themselves).
#
#   restore <tarball>  [--as <name>] [--force]
#       Recreate a deployment from a tarball. The original name is used unless
#       --as overrides it.
#
# The tarball is portable across hosts: it contains the config, secrets,
# lockfile, build history, and the Dockerfile template — everything needed
# for `nelly deploy` to rebuild and start the deployment.

set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

usage() {
    cat <<'EOF'
backup.sh backup  <deploy_dir> [--out PATH] [--include-logs]
backup.sh restore <tarball>    [--as <name>] [--force]
EOF
}

sub="${1:-}"; shift || true
case "$sub" in

    backup)
        DEPLOY_DIR="${1:-}"; shift || true
        [[ -d "$DEPLOY_DIR" ]] || die "not a deployment: $DEPLOY_DIR"
        validate_config "$DEPLOY_DIR" >/dev/null

        OUT=""
        INCLUDE_LOGS=0
        while (( $# > 0 )); do
            case "$1" in
                --out)          OUT="$2"; shift 2 ;;
                --include-logs) INCLUDE_LOGS=1; shift ;;
                *) die "unknown flag: $1" ;;
            esac
        done

        name="$(basename "$DEPLOY_DIR")"
        ts="$(date -u +%Y%m%d-%H%M%S)"
        [[ -z "$OUT" ]] && OUT="${name}-${ts}.tar.gz"

        # Build the file list. We exclude apps/ (will be re-fetched), .build/
        # (transient), the lock file, and—by default—logs/.
        declare -a EXCLUDES=(
            --exclude='apps'
            --exclude='.build'
            --exclude='.nelly.lock'
        )
        (( INCLUDE_LOGS )) || EXCLUDES+=(--exclude='logs')

        info "writing backup → $OUT"
        # Use tar's -C to make paths relative; resulting tarball restores to <name>/...
        tar -czf "$OUT" "${EXCLUDES[@]}" \
            -C "$(dirname "$DEPLOY_DIR")" "$name"

        # Print a small summary
        size="$(du -h "$OUT" | cut -f1)"
        info "  size: $size"
        info "  contents:"
        tar -tzf "$OUT" | sed 's/^/    /'
        ;;

    restore)
        TARBALL="${1:-}"; shift || true
        [[ -f "$TARBALL" ]] || die "no such file: $TARBALL"
        AS=""; FORCE=0
        while (( $# > 0 )); do
            case "$1" in
                --as)    AS="$2"; shift 2 ;;
                --force) FORCE=1; shift ;;
                *) die "unknown flag: $1" ;;
            esac
        done

        # Stage to a temp dir, pick the top-level deployment name, then move.
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        tar -xzf "$TARBALL" -C "$tmp"

        # Detect the top-level directory inside the tarball.
        mapfile -t roots < <(find "$tmp" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
        (( ${#roots[@]} == 1 )) || die "unexpected tarball layout (need exactly one top-level dir)"
        src_name="${roots[0]}"

        new_name="${AS:-$src_name}"
        [[ "$new_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$ ]] || die "invalid name: $new_name"

        dest="$NELLY_ROOT/containers/$new_name"
        if [[ -e "$dest" ]]; then
            if (( FORCE )); then
                rm -rf "$dest"
            else
                die "$dest already exists (pass --force to overwrite)"
            fi
        fi

        mv "$tmp/$src_name" "$dest"

        # Make sure the dirs the runtime expects exist.
        mkdir -p "$dest/apps" "$dest/logs/cron"

        if [[ -n "$AS" ]]; then
            "$LIB/config.sh" set "$dest" '.container_name' "$new_name" >/dev/null
            "$LIB/config.sh" set "$dest" '.image_name'     "${new_name,,}" >/dev/null
        fi
        validate_config "$dest" >/dev/null

        # Tighten .env permissions in case the tarball had different bits.
        [[ -f "$dest/def/.env" ]] && chmod 600 "$dest/def/.env"

        info "restored deployment '$new_name'"
        info "next: nelly deploy $new_name"
        ;;

    *) usage; exit 2 ;;
esac
