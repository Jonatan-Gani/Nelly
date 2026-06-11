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
        # Deliberately NOT calling validate_config. Backup must preserve
        # whatever state exists; refusing to back up a deployment because
        # of a policy rule (e.g. `.allow_dangerous_health_cmd`) is worse
        # than backing up bad state. Restore re-validates on the
        # destination, so policy can't be smuggled in silently.
        #
        # JSON validity is still checked — fundamentally-broken state
        # (unparseable config) is worth refusing on, because nothing
        # downstream can reason about it.
        if [[ -f "$DEPLOY_DIR/def/config.json" ]]; then
            jq -e . "$DEPLOY_DIR/def/config.json" >/dev/null \
                || die "config.json is not valid JSON: $DEPLOY_DIR/def/config.json"
        fi

        OUT=""
        INCLUDE_LOGS=0
        INCLUDE_SECRETS=0
        NO_COMPRESS=0
        DETERMINISTIC=0
        QUIET=0
        while (( $# > 0 )); do
            case "$1" in
                --out)             OUT="$2"; shift 2 ;;
                --include-logs)    INCLUDE_LOGS=1; shift ;;
                --include-secrets) INCLUDE_SECRETS=1; shift ;;
                # --no-compress + --deterministic: dedup-friendly mode used by
                # `nelly snapshot`. Off-site stores (restic, borg) chunk + compress
                # themselves; a gzip layer here cascades a one-byte change through
                # the whole stream and destroys their chunk dedup, so unchanged
                # bundles re-upload in full every run. Sorted names + numeric
                # owners keep the tar stream stable across hosts.
                --no-compress)     NO_COMPRESS=1; shift ;;
                --deterministic)   DETERMINISTIC=1; shift ;;
                --quiet)           QUIET=1; shift ;;
                *) die "unknown flag: $1" ;;
            esac
        done

        name="$(basename "$DEPLOY_DIR")"
        ts="$(date -u +%Y%m%d-%H%M%S)"
        if [[ -z "$OUT" ]]; then
            if (( NO_COMPRESS )); then
                OUT="${name}-${ts}.tar"
            else
                OUT="${name}-${ts}.tar.gz"
            fi
        fi

        # Build the file list. apps/ is excluded (will be re-fetched), .build/
        # is transient, the lockfile too. Secrets and logs are excluded by
        # default — secrets to keep them from sprawling, logs because they'd
        # bloat the tarball.
        declare -a EXCLUDES=(
            --exclude='apps'
            --exclude='.build'
            --exclude='.nelly.lock'
        )
        (( INCLUDE_LOGS )) || EXCLUDES+=(--exclude='logs')
        if (( INCLUDE_SECRETS )); then
            (( QUIET )) || warn "including secrets in backup — handle this file like a password (mode 0600 on disk; do NOT commit it anywhere)"
        else
            EXCLUDES+=(--exclude='def/.env' --exclude='def/secrets')
        fi

        declare -a TAR_FLAGS=()
        (( NO_COMPRESS )) || TAR_FLAGS+=(-z)
        if (( DETERMINISTIC )); then
            # --sort=name removes ls-order non-determinism. --numeric-owner
            # avoids per-host uid/gid name resolution. --format=gnu pins the
            # archive format so different tar builds emit identical streams.
            # Mtime is intentionally NOT zeroed: unchanged file content has
            # unchanged mtime, so the tar stream is still stable; zeroing
            # would break post-restore tooling that checks file ages.
            TAR_FLAGS+=(--format=gnu --sort=name --numeric-owner)
        fi

        (( QUIET )) || info "writing backup → $OUT"
        # Use tar's -C to make paths relative; resulting tarball restores to <name>/...
        tar -c "${TAR_FLAGS[@]}" -f "$OUT" "${EXCLUDES[@]}" \
            -C "$(dirname "$DEPLOY_DIR")" "$name"

        if (( ! QUIET )); then
            size="$(du -h "$OUT" | cut -f1)"
            info "  size: $size"
            info "  contents:"
            if (( NO_COMPRESS )); then
                tar -tf "$OUT" | sed 's/^/    /'
            else
                tar -tzf "$OUT" | sed 's/^/    /'
            fi
        fi
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
        # Auto-detect gzip vs plain tar so restore works on bundles that used
        # --no-compress (e.g. snapshot bundles tuned for restic dedup).
        tar -xf "$TARBALL" -C "$tmp"

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
