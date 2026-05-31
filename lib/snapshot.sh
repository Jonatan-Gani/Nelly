#!/usr/bin/env bash
# lib/snapshot.sh — produce a restore-ready bundle for off-site backup.
#
# The bundle is the contract with the backup layer (restic, borg, etc.):
# everything needed to reconstruct every container nelly manages — same
# images, same volumes, same secrets — on a freshly flashed host, given
# only the off-site repo + the password manager.
#
# Layout at $OUT (default: /var/backups/nelly):
#   BUNDLE_VERSION              "1"
#   README.txt                  restore instructions
#   snapshot.json               generation metadata + per-deployment outcomes
#   fleet-manifest.json         the "what is running" source of truth
#   deployments/<name>/
#     tarball.tar               full deployment dir (uncompressed for restic dedup)
#     container-inspect.json    docker inspect, if the container exists
#     image-digest.txt          image reference pinned to @sha256:... (when resolvable)
#     volumes/<slug>.tar        uncompressed, deterministic tar of each declared
#                               host bind-mount, taken while quiesced
#     volumes/<slug>.meta.json  host_path, container_path, mode, sha256, size_bytes
#     dumps/                    where hooks.pre_snapshot can drop pg_dump/mysqldump output
#   nelly-state/
#     bot.tar                   $NELLY_ROOT/bot if present (token, allowed users, audit log)
#     nelly-commit.txt          git HEAD of nelly itself (for reproducibility)
#
# Design choices worth knowing
# ----------------------------
#
# 1. Uncompressed tar inside the bundle. Off-site repos (restic v2 +
#    compression, borg, etc.) chunk and compress themselves. A gzip layer
#    here would cascade any one-byte change through the whole stream and
#    destroy the chunk dedup, re-uploading unchanged volumes in full
#    every night. tar streams are also produced with --sort=name and
#    --numeric-owner so the bytes are stable across hosts.
#
# 2. Always-restart guard. If we stop a container to tar its volumes, we
#    restart it no matter how the script exits — including SIGINT,
#    SIGTERM, or an unexpected `die`. A backup that takes a service down
#    and leaves it down is worse than a missed backup.
#
# 3. backup.skip_volumes. When hooks.pre_snapshot drops a logical dump
#    (pg_dump, mysqldump) into dumps/, list the corresponding data-dir
#    bind-mount in `.backup.skip_volumes` so it is NOT also quiesce-tarred.
#    Otherwise you back up the same database twice — once cleanly, once as
#    a heavier on-disk copy — and the on-disk one is the torn-file risk we
#    are here to avoid.
#
# 4. Atomic <out>.new swap. The bundle is built under a sibling directory
#    and renamed into place at the end. A half-written bundle never
#    replaces the last known-good one.
#
# 5. Permissions. umask 077 is set at the start of create, so every file
#    and dir lands at 0600/0700. The final $OUT is forced to 0700. The
#    bundle holds secrets in cleartext on the local disk between off-site
#    runs — the off-site copy is encrypted, but the local one isn't.
#
# Subcommands:
#   snapshot create  [--out DIR] [--no-quiesce] [--no-volumes] [--no-secrets]
#                    [--exclude NAME]... [--only NAME]... [--quiesce-time N]
#                    [--no-verify]
#   snapshot verify  [--out DIR]
#   snapshot list    [--out DIR]
#   snapshot install-hook   [--hook-dir DIR] [--name NAME]
#   snapshot uninstall-hook [--hook-dir DIR] [--name NAME]

set -euo pipefail
LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=common.sh
[[ "$(type -t info)" == "function" ]] || source "$LIB/common.sh"
# shellcheck source=hooks.sh
source "$LIB/hooks.sh"

BUNDLE_VERSION=1
DEFAULT_OUT="${NELLY_BACKUP_DIR:-/var/backups/nelly}"
DEFAULT_HOOK_DIR="${NELLY_RESTIC_HOOK_DIR:-/etc/restic/pre-backup.d}"
DEFAULT_HOOK_NAME="50-nelly-snapshot"
DEFAULT_QUIESCE_TIME=30

# Tracks containers we stopped during this run so the EXIT trap can
# restart them no matter how we exit. Container names are pushed at
# `docker stop` time and removed once we've confirmed a clean restart.
declare -a NELLY_SNAPSHOT_STOPPED=()

usage() {
    cat <<'EOF'
snapshot.sh create  [--out DIR] [--no-quiesce] [--no-volumes] [--no-secrets]
                    [--exclude NAME]... [--only NAME]... [--quiesce-time N]
                    [--no-verify]
snapshot.sh verify  [--out DIR]
snapshot.sh list    [--out DIR]
snapshot.sh install-hook   [--hook-dir DIR] [--name NAME]
snapshot.sh uninstall-hook [--hook-dir DIR] [--name NAME]
EOF
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_now()         { date -u +%Y-%m-%dT%H:%M:%SZ; }
_secs()        { date +%s; }
_slugify()     { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_\+//; s/_\+$//'; }
_host()        { hostname 2>/dev/null || echo unknown; }
_nelly_commit() {
    [[ -d "$NELLY_ROOT/.git" ]] || { echo ""; return; }
    git -C "$NELLY_ROOT" rev-parse HEAD 2>/dev/null || echo ""
}

_deployments() {
    [[ -d "$NELLY_ROOT/containers" ]] || return 0
    local d name
    for d in "$NELLY_ROOT/containers"/*/; do
        name="$(basename "${d%/}")"
        [[ "$name" == "template" ]] && continue
        [[ -f "$d/def/config.json" ]] || continue
        printf '%s\n' "$name"
    done
}

# Push / remove the global stopped-containers registry. The EXIT trap reads
# the registry and restarts anything still in it.
_track_stopped() { NELLY_SNAPSHOT_STOPPED+=("$1"); }
_untrack_stopped() {
    local target="$1" i
    local -a kept=()
    if (( ${#NELLY_SNAPSHOT_STOPPED[@]} > 0 )); then
        for i in "${NELLY_SNAPSHOT_STOPPED[@]}"; do
            [[ "$i" == "$target" ]] && continue
            kept+=("$i")
        done
    fi
    NELLY_SNAPSHOT_STOPPED=("${kept[@]}")
}

# Always-restart guard — runs on EXIT, INT, TERM. If anything we stopped
# is still down, bring it back up. Best-effort: a failure here is logged
# but cannot itself raise (we may already be unwinding).
_restart_guard() {
    local rc=$?
    local c
    if (( ${#NELLY_SNAPSHOT_STOPPED[@]} > 0 )); then
        for c in "${NELLY_SNAPSHOT_STOPPED[@]}"; do
            [[ -z "$c" ]] && continue
            err "  cleanup: restarting $c (guard)"
            docker start "$c" >/dev/null 2>&1 \
                || err "  cleanup: docker start failed for $c — MANUAL INTERVENTION REQUIRED"
        done
        NELLY_SNAPSHOT_STOPPED=()
    fi
    return "$rc"
}

# Resolve an image reference to a fully-pinned image@sha256:... form.
# Falls back to the image tag if no digest is known locally.
_pin_image_digest() {
    local image="$1"
    [[ -n "$image" ]] || { echo ""; return; }
    command -v docker >/dev/null 2>&1 || { echo "$image"; return; }
    local digest
    digest="$(docker inspect --type=image -f '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
    if [[ -n "$digest" && "$digest" == *@sha256:* ]]; then
        # If $image already carries a tag, preserve it; otherwise emit repo@digest.
        case "$image" in
            *@sha256:*) printf '%s' "$image" ;;
            *:*)        printf '%s@%s' "$image" "${digest##*@}" ;;
            *)          printf '%s' "$digest" ;;
        esac
        return
    fi
    # No RepoDigest available (locally-built image that was never pushed) — at
    # least record the image ID so a reconstruction has *something* to verify.
    local id
    id="$(docker inspect --type=image -f '{{.Id}}' "$image" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
        printf '%s (id=%s)' "$image" "$id"
    else
        printf '%s' "$image"
    fi
}

# Run hooks.pre_snapshot / post_snapshot if defined. Reuses the same
# security model as the existing hook runner. Returns the hook's exit
# code so the caller can decide whether to proceed.
_run_snapshot_hook() {
    local deploy_dir="$1" hook="$2" snapshot_dir="$3"
    NELLY_SNAPSHOT_DIR="$snapshot_dir" \
    NELLY_SNAPSHOT_OUT="$snapshot_dir" \
        run_hook "$deploy_dir" "$hook"
}

# Return 0 if $needle is one of the absolute paths in `.backup.skip_volumes`.
_volume_is_skipped() {
    local needle="$1" config="$2"
    [[ -f "$config" ]] || return 1
    local match
    match="$(jq -r --arg n "$needle" \
        '(.backup.skip_volumes // []) | map(select(. == $n)) | length' "$config" 2>/dev/null || echo 0)"
    [[ "$match" != "0" ]]
}

# ---------------------------------------------------------------------------
# fleet manifest
# ---------------------------------------------------------------------------

# Emit one JSON object describing a single deployment.
_deployment_manifest_entry() {
    local name="$1"
    local dir="$NELLY_ROOT/containers/$name"
    local config="$dir/def/config.json"
    [[ -f "$config" ]] || { echo "{}"; return; }

    local container_name image image_pinned base_image
    container_name="$(jqget "$config" '.container_name' "$name")"
    image="$(cat "$dir/def/last_image.txt" 2>/dev/null || echo "")"
    image_pinned="$(_pin_image_digest "$image")"
    base_image="$(jqget "$config" '.base_image' '')"

    local state="absent" running_image_id="" started_at=""
    if command -v docker >/dev/null 2>&1 \
        && docker inspect "$container_name" >/dev/null 2>&1; then
        state="$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo unknown)"
        running_image_id="$(docker inspect -f '{{.Image}}' "$container_name" 2>/dev/null || echo "")"
        started_at="$(docker inspect -f '{{.State.StartedAt}}' "$container_name" 2>/dev/null || echo "")"
    fi

    local commits='{}'
    [[ -f "$dir/def/commits.lock.json" ]] && commits="$(cat "$dir/def/commits.lock.json")"

    # Env-file paths to flag for the backup side. Absolute, so the manifest is
    # standalone — anyone reading it knows exactly which host files matter.
    local env_files='[]'
    if [[ -f "$dir/def/.env" ]]; then
        env_files="$(jq -nc --arg p "$dir/def/.env" '[{path:$p, purpose:"global"}]')"
    fi
    if [[ -d "$dir/def/secrets" ]]; then
        local f appname extra
        for f in "$dir/def/secrets"/*.env; do
            [[ -f "$f" ]] || continue
            appname="$(basename "$f" .env)"
            extra="$(jq -nc --arg p "$f" --arg a "app:$appname" '{path:$p, purpose:$a}')"
            env_files="$(echo "$env_files" | jq --argjson e "$extra" '. + [$e]')"
        done
    fi

    jq -n \
        --arg name "$name" \
        --arg cn "$container_name" \
        --arg img "$image" \
        --arg pin "$image_pinned" \
        --arg base "$base_image" \
        --arg state "$state" \
        --arg rimg "$running_image_id" \
        --arg started "$started_at" \
        --argjson cfg "$(cat "$config")" \
        --argjson commits "$commits" \
        --argjson env_files "$env_files" \
        '{
            name:           $name,
            container_name: $cn,
            image:          (if $img == "" then null else $img end),
            image_pinned:   (if $pin == "" then null else $pin end),
            base_image:     (if $base == "" then null else $base end),
            state:          $state,
            running_image_id: (if $rimg == "" then null else $rimg end),
            started_at:     (if $started == "" then null else $started end),
            tags:           ($cfg.tags // []),
            apps: ($cfg.apps // []) | map({
                name:       .app_name,
                source:     (.source // (if .git_url then
                                {type:"git", url:.git_url, ref:(.ref // .branch // "main")}
                              else null end)),
                schedule:   (.schedule  // null),
                entrypoint: (.entrypoint // null),
                commit:     ($commits[.app_name] // null)
            }),
            network: {
                name:    ($cfg.network.network_name   // null),
                ports:   ($cfg.network.ports          // []),
                extra:   ($cfg.network.extra_networks // []),
                aliases: ($cfg.network.aliases        // []),
                hostname:($cfg.network.hostname       // null),
                static_ip:($cfg.network.static_ip     // null)
            },
            volumes:    ($cfg.volumes  // []),
            backup:     ($cfg.backup   // {}),
            resources:  ($cfg.resources // {}),
            health:     ($cfg.health    // {}),
            restart:    ($cfg.restart   // "unless-stopped"),
            env_files:  $env_files
        }'
}

# ---------------------------------------------------------------------------
# per-deployment snapshot
# ---------------------------------------------------------------------------

# Returns 0 on success, non-zero on failure. The bundle as a whole tolerates
# per-deployment failures (recorded in snapshot.json) so one bad container
# does not block backing up everything else.
_snapshot_one_deployment() {
    local name="$1" out_root="$2" do_quiesce="$3" do_volumes="$4" do_secrets="$5" quiesce_time="$6"
    local dir="$NELLY_ROOT/containers/$name"
    local dest="$out_root/deployments/$name"
    mkdir -p "$dest/volumes" "$dest/dumps"

    local container_name
    container_name="$(jqget "$dir/def/config.json" '.container_name' "$name")"

    info "snapshotting deployment: $name (container: $container_name)"

    # 1. pre_snapshot hook — runs while the container is still live so that
    #    e.g. pg_dump can talk to a running database. Drop output into
    #    $NELLY_SNAPSHOT_DIR/dumps/. A non-zero exit fails the whole
    #    deployment snapshot — silently skipping a failed dump would leave
    #    the bundle missing data that backup.skip_volumes assumes is there.
    #
    # Capture the hook's rc directly, not via `if !` — under `if !`, `$?`
    # reads the if-construct's exit (always 0 for the then-branch), not the
    # original command's exit code.
    local pre_hook_rc=0
    _run_snapshot_hook "$dir" pre_snapshot "$dest" || pre_hook_rc=$?
    if (( pre_hook_rc != 0 )); then
        err "  pre_snapshot hook failed for $name (rc=$pre_hook_rc) — bundle is incomplete"
        return "$pre_hook_rc"
    fi

    # 2. Deployment tarball via the existing backup.sh path. Uncompressed +
    #    deterministic so restic chunks dedup across runs. Includes secrets
    #    by default (the off-site copy is encrypted; the local bundle is
    #    mode 0700).
    local backup_args=( "$dir" --out "$dest/tarball.tar" --no-compress --deterministic --quiet )
    (( do_secrets )) && backup_args+=( --include-secrets )
    if ! "$LIB/backup.sh" backup "${backup_args[@]}" >/dev/null 2>&1; then
        err "  tarball failed for $name"
        return 1
    fi

    # 3. docker inspect for the running container — captures the exact image
    #    digest in use, mount info, networks, etc.
    if command -v docker >/dev/null 2>&1 \
        && docker inspect "$container_name" >/dev/null 2>&1; then
        docker inspect "$container_name" > "$dest/container-inspect.json" 2>/dev/null || true
    fi

    # 4. Image digest pinning — the "redeploy from git" reproducibility anchor.
    local image image_pinned
    image="$(cat "$dir/def/last_image.txt" 2>/dev/null || echo "")"
    image_pinned="$(_pin_image_digest "$image")"
    [[ -n "$image_pinned" ]] && printf '%s\n' "$image_pinned" > "$dest/image-digest.txt"

    # 5. Bind-mount volumes — quiesce, tar, restart.
    local vol_rc=0
    if (( do_volumes )); then
        _snapshot_volumes "$name" "$dir" "$dest" "$container_name" "$do_quiesce" "$quiesce_time" \
            || vol_rc=$?
        if (( vol_rc != 0 )); then
            warn "  volume snapshot had issues for $name (rc=$vol_rc, see $dest/volumes/)"
        fi
    fi

    # 6. post_snapshot hook. Failures here are warned but don't fail the
    #    deployment — the data is already on disk.
    _run_snapshot_hook "$dir" post_snapshot "$dest" \
        || warn "  post_snapshot hook failed for $name"

    # If quiesce failed to restart, that's a HARD failure even if the tar
    # files are intact — the operator needs to know.
    if (( vol_rc == 2 )); then
        return 2
    fi
    return 0
}

# Snapshot each host bind-mounted volume. Default behavior: stop the
# container, tar each declared host path, start the container. Skipping
# quiesce is allowed but warned — restic walking a live volume is exactly
# the torn-files hazard we are here to prevent.
#
# Returns:
#   0   all volumes tarred (or no volumes declared)
#   1   one or more tarballs failed but container is back up
#   2   container failed to restart — manual intervention required
_snapshot_volumes() {
    local name="$1" dir="$2" dest="$3" container_name="$4" do_quiesce="$5" quiesce_time="$6"
    local config="$dir/def/config.json"
    local rc=0
    mapfile -t VOLS < <(jq -r '.volumes[]?' "$config")
    if (( ${#VOLS[@]} == 0 )); then
        return 0
    fi

    # Filter out volumes the user has flagged as covered by a dump
    # (backup.skip_volumes). Recorded in the per-deployment volumes/
    # directory as skipped-volumes.json for forensics.
    declare -a TAR_VOLS=()
    declare -a SKIPPED_VOLS=()
    local v host_side
    for v in "${VOLS[@]}"; do
        host_side="${v%%:*}"
        if _volume_is_skipped "$host_side" "$config"; then
            SKIPPED_VOLS+=("$v")
        else
            TAR_VOLS+=("$v")
        fi
    done
    if (( ${#SKIPPED_VOLS[@]} > 0 )); then
        info "  skipping ${#SKIPPED_VOLS[@]} volume(s) (backup.skip_volumes — assumed covered by hooks.pre_snapshot dumps)"
        printf '%s\n' "${SKIPPED_VOLS[@]}" \
            | jq -R . | jq -s . > "$dest/volumes/skipped-volumes.json"
    fi
    if (( ${#TAR_VOLS[@]} == 0 )); then
        return 0
    fi

    # Quiesce. Only stop if the container is actually running.
    local stopped=0
    if (( do_quiesce )) \
        && command -v docker >/dev/null 2>&1 \
        && docker inspect "$container_name" >/dev/null 2>&1 \
        && [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)" == "true" ]]; then
        info "  quiescing $container_name (stop --time=$quiesce_time)"
        if docker stop --time="$quiesce_time" "$container_name" >/dev/null 2>&1; then
            stopped=1
            # Register with the always-restart guard immediately, BEFORE any
            # tar runs — that way a die / SIGINT / disk-full mid-tar still
            # brings the container back up via the EXIT trap.
            _track_stopped "$container_name"
        else
            warn "  failed to stop $container_name; snapshotting live (torn-file risk)"
        fi
    elif (( ! do_quiesce )); then
        warn "  --no-quiesce: tarring live volumes for $container_name (torn-file risk)"
    fi

    local container_side mode slug tarball meta sha size
    for v in "${TAR_VOLS[@]}"; do
        host_side="${v%%:*}"
        local rest="${v#*:}"
        container_side="${rest%%:*}"
        mode=""
        [[ "$rest" == *:* ]] && mode="${rest#*:}"
        if [[ ! -d "$host_side" && ! -f "$host_side" ]]; then
            warn "    volume host path missing: $host_side (skipping)"
            rc=1
            continue
        fi
        slug="$(_slugify "$host_side")"
        tarball="$dest/volumes/${slug}.tar"
        meta="$dest/volumes/${slug}.meta.json"
        info "    tarring $host_side → $(basename "$tarball")"
        # Uncompressed + deterministic: lets restic / borg dedup unchanged
        # volumes across runs (a gzip layer here would re-upload everything
        # nightly even for one-byte changes). --sort=name removes filesystem
        # ls-order variability; --numeric-owner removes per-host uid/gid
        # name-resolution variability.
        if ! tar --warning=no-file-changed \
                 --sort=name --numeric-owner \
                 -cf "$tarball" \
                 -C "$(dirname "$host_side")" "$(basename "$host_side")" 2>/dev/null; then
            warn "    tar failed for $host_side"
            rc=1
            continue
        fi
        sha="$(sha256sum "$tarball" | cut -d' ' -f1)"
        size="$(stat -c %s "$tarball")"
        jq -n \
            --arg host "$host_side" \
            --arg cont "$container_side" \
            --arg mode "$mode" \
            --arg sha "$sha" \
            --argjson size "$size" \
            '{host_path: $host,
              container_path: $cont,
              mode: (if $mode == "" then null else $mode end),
              sha256: $sha,
              size_bytes: $size}' > "$meta"
    done

    # Restart, verify, then untrack. Untrack is last so the guard is still
    # armed if `docker start` somehow returns 0 but the container isn't
    # actually running.
    if (( stopped )); then
        info "  restarting $container_name"
        if docker start "$container_name" >/dev/null 2>&1; then
            local running
            running="$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || echo false)"
            if [[ "$running" == "true" ]]; then
                _untrack_stopped "$container_name"
            else
                err "  $container_name is NOT running after restart — manual intervention required"
                rc=2
            fi
        else
            err "  FAILED to restart $container_name — guard will retry on exit"
            rc=2
        fi
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# nelly-state (bot, nelly's own commit)
# ---------------------------------------------------------------------------

_snapshot_nelly_state() {
    local out_root="$1"
    local dest="$out_root/nelly-state"
    mkdir -p "$dest"

    # bot/ — Telegram token (mode 0600), allowed users, audit log. Same
    # client-side-encryption argument as the deployment .env files.
    if [[ -d "$NELLY_ROOT/bot" ]]; then
        info "snapshotting bot/ state"
        # Uncompressed + deterministic — same restic dedup story.
        tar --warning=no-file-changed --sort=name --numeric-owner \
            -cf "$dest/bot.tar" -C "$NELLY_ROOT" bot 2>/dev/null \
            || warn "  bot/ tarball failed"
    fi

    local commit; commit="$(_nelly_commit)"
    [[ -n "$commit" ]] && printf '%s\n' "$commit" > "$dest/nelly-commit.txt"
}

# ---------------------------------------------------------------------------
# README + snapshot metadata
# ---------------------------------------------------------------------------

_write_readme() {
    local out_root="$1"
    cat > "$out_root/README.txt" <<'EOF'
nelly restore bundle
====================

This directory is the contract with the off-site backup layer (restic, borg).
It is regenerated atomically before every backup run; the layout is stable.

What's here
-----------

BUNDLE_VERSION
    Schema version of this bundle (currently "1").

snapshot.json
    Generation metadata: timestamp, host, nelly version, durations, and
    per-deployment success/failure record.

fleet-manifest.json
    The single source of truth for what was running at snapshot time, in a
    form a human can reconstruct from: container name, image+digest, base
    image, ports, networks, volumes, env-file paths, tags, schedules, and
    each app's pinned git commit.

deployments/<name>/tarball.tar
    The full deployment directory: config.json, secrets, lockfile, build
    history, Dockerfile, release records. Uncompressed so restic / borg
    dedup unchanged tarballs across runs. Restorable with:
        nelly restore deployments/<name>/tarball.tar

deployments/<name>/container-inspect.json
    Output of `docker inspect <container>` at snapshot time. Captures the
    exact image digest, mounts, networks, and runtime state.

deployments/<name>/image-digest.txt
    The image reference pinned to @sha256:... so a rebuild produces the
    same bits, not a moving :latest target.

deployments/<name>/volumes/<slug>.tar
    One tarball per declared host bind-mount, taken while the container was
    stopped (unless --no-quiesce was used). Uncompressed and deterministic
    (--sort=name --numeric-owner) for dedup. The .meta.json sibling lists
    host_path, container_path, mode, sha256, size.

deployments/<name>/volumes/skipped-volumes.json
    Volumes listed in `.backup.skip_volumes` — assumed to be covered by a
    logical dump from hooks.pre_snapshot. Only present if any were skipped.

deployments/<name>/dumps/
    Where hooks.pre_snapshot can drop logical dumps (pg_dump, mysqldump,
    etc.). Empty by default.

nelly-state/bot.tar
    Telegram bot state (token, allowed users, audit log). Only present if
    bot/ exists.

nelly-state/nelly-commit.txt
    The git HEAD of nelly itself at snapshot time.

How to restore on a freshly flashed host
----------------------------------------

1. Install nelly at the recorded commit:
       git clone <repo> ~/nelly && cd ~/nelly
       git checkout $(cat nelly-state/nelly-commit.txt)
       bash install.sh

2. Restore each deployment:
       for t in deployments/*/tarball.tar; do
           nelly restore "$t"
       done

3. For each deployment with volumes, restore the host paths:
       cd deployments/<name>/volumes/
       for v in *.tar; do
           meta="${v%.tar}.meta.json"
           dest="$(jq -r .host_path "$meta")"
           sudo mkdir -p "$(dirname "$dest")"
           sudo tar -xf "$v" -C "$(dirname "$dest")"
       done

4. Apply any logical dumps from deployments/<name>/dumps/ per the database's
   restore procedure.

5. Bring each deployment up:
       nelly deploy <name>

6. Verify against fleet-manifest.json — same images, same volumes, same
   secrets — without guessing.
EOF
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

create_snapshot() {
    local out="$DEFAULT_OUT"
    local do_quiesce=1 do_volumes=1 do_secrets=1 do_verify=1
    local quiesce_time="$DEFAULT_QUIESCE_TIME"
    declare -a exclude=() only=()
    while (( $# > 0 )); do
        case "$1" in
            --out)          out="$2"; shift 2 ;;
            --no-quiesce)   do_quiesce=0; shift ;;
            --no-volumes)   do_volumes=0; shift ;;
            --no-secrets)   do_secrets=0; shift ;;
            --no-verify)    do_verify=0; shift ;;
            --quiesce-time) quiesce_time="$2"; shift 2 ;;
            --exclude)      exclude+=("$2"); shift 2 ;;
            --only)         only+=("$2"); shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done

    require_cmd jq tar sha256sum

    # Files / dirs created from here on land at 0600 / 0700 by default.
    # The bundle holds cleartext secrets between off-site runs.
    umask 077

    # Arm the always-restart guard immediately, BEFORE we touch any
    # container. From this point until normal exit, any container we stop
    # is registered with the guard and restarted no matter how we exit.
    trap _restart_guard EXIT INT TERM

    # The bundle is built under a sibling .new directory and swapped in
    # atomically at the end. A half-written bundle never replaces the last
    # known-good one — important because restic may walk $OUT between runs.
    local out_new="${out}.new"
    local out_old="${out}.old"
    rm -rf "$out_new" "$out_old"
    mkdir -p "$out_new/deployments" "$out_new/nelly-state"
    chmod 700 "$out_new"
    echo "$BUNDLE_VERSION" > "$out_new/BUNDLE_VERSION"

    local started_at; started_at="$(_now)"
    local t_start; t_start="$(_secs)"

    info "building bundle at $out (staging in $out_new)"

    local results='[]'
    local n_ok=0 n_fail=0

    while IFS= read -r name; do
        if (( ${#only[@]} > 0 )); then
            local hit=0
            for o in "${only[@]}"; do [[ "$o" == "$name" ]] && hit=1; done
            (( hit )) || continue
        fi
        for e in "${exclude[@]}"; do
            [[ "$e" == "$name" ]] && { info "skipping (excluded): $name"; continue 2; }
        done

        local d_start; d_start="$(_secs)"
        local outcome="success" err_msg="" d_rc=0
        _snapshot_one_deployment \
            "$name" "$out_new" "$do_quiesce" "$do_volumes" "$do_secrets" "$quiesce_time" \
            || d_rc=$?
        if (( d_rc == 0 )); then
            n_ok=$((n_ok+1))
        else
            outcome="failed"
            err_msg="rc=$d_rc (see logs)"
            n_fail=$((n_fail+1))
        fi
        local d_end; d_end="$(_secs)"
        local d_dur=$((d_end - d_start))
        results="$(echo "$results" | jq \
            --arg name "$name" \
            --arg outcome "$outcome" \
            --arg err "$err_msg" \
            --argjson dur "$d_dur" \
            '. + [{deployment:$name, outcome:$outcome, duration_seconds:$dur,
                   error:(if $err == "" then null else $err end)}]')"
    done < <(_deployments)

    # Fleet manifest — one pass over all deployments after the per-deployment
    # snapshots have already captured docker inspect etc.
    info "writing fleet-manifest.json"
    local manifest='[]'
    while IFS= read -r name; do
        if (( ${#only[@]} > 0 )); then
            local hit=0
            for o in "${only[@]}"; do [[ "$o" == "$name" ]] && hit=1; done
            (( hit )) || continue
        fi
        for e in "${exclude[@]}"; do
            [[ "$e" == "$name" ]] && continue 2
        done
        local entry; entry="$(_deployment_manifest_entry "$name")"
        manifest="$(echo "$manifest" | jq --argjson e "$entry" '. + [$e]')"
    done < <(_deployments)

    local nelly_version=""
    [[ -x "$NELLY_ROOT/bin/nelly" ]] \
        && nelly_version="$("$NELLY_ROOT/bin/nelly" --version 2>/dev/null | awk '{print $2}')"

    jq -n \
        --argjson v "$BUNDLE_VERSION" \
        --arg ts "$started_at" \
        --arg host "$(_host)" \
        --arg root "$NELLY_ROOT" \
        --arg nv "$nelly_version" \
        --arg commit "$(_nelly_commit)" \
        --argjson deployments "$manifest" \
        '{
            schema_version: $v,
            generated_at:   $ts,
            host:           $host,
            nelly_root:     $root,
            nelly_version:  (if $nv == "" then null else $nv end),
            nelly_commit:   (if $commit == "" then null else $commit end),
            deployments:    $deployments
        }' > "$out_new/fleet-manifest.json"

    _snapshot_nelly_state "$out_new"
    _write_readme "$out_new"

    local finished_at; finished_at="$(_now)"
    local t_end; t_end="$(_secs)"
    local total_dur=$((t_end - t_start))
    local total_bytes
    total_bytes="$(du -sb "$out_new" 2>/dev/null | awk '{print $1}')"

    jq -n \
        --argjson v "$BUNDLE_VERSION" \
        --arg started "$started_at" \
        --arg finished "$finished_at" \
        --arg host "$(_host)" \
        --argjson dur "$total_dur" \
        --argjson bytes "${total_bytes:-0}" \
        --argjson n_ok "$n_ok" \
        --argjson n_fail "$n_fail" \
        --argjson results "$results" \
        --argjson opts "$(jq -n \
                --argjson quiesce "$do_quiesce" \
                --argjson volumes "$do_volumes" \
                --argjson secrets "$do_secrets" \
                --argjson qtime "$quiesce_time" \
                '{quiesce:($quiesce==1), volumes:($volumes==1),
                  secrets:($secrets==1), quiesce_time_seconds:$qtime}')" \
        '{
            schema_version:   $v,
            started_at:       $started,
            finished_at:      $finished,
            duration_seconds: $dur,
            host:             $host,
            size_bytes:       $bytes,
            deployments_ok:   $n_ok,
            deployments_failed: $n_fail,
            options:          $opts,
            results:          $results
        }' > "$out_new/snapshot.json"

    # Atomic-ish swap. Two operations: rename current → .old, rename new →
    # current. A reader catching us mid-swap sees either the old bundle or
    # nothing for a moment; restic's pre-backup hook makes that impossible
    # in the intended deployment, but the dance keeps the worst case bounded.
    if [[ -d "$out" ]]; then
        mv "$out" "$out_old"
    fi
    mv "$out_new" "$out"
    chmod 700 "$out"
    rm -rf "$out_old"

    local summary
    summary="$(numfmt --to=iec --suffix=B "${total_bytes:-0}" 2>/dev/null || echo "${total_bytes:-0}B")"

    # Self-verify before we let the caller think we're done. The whole point
    # of the install-hook flow is that a corrupt bundle should trip a hard
    # fail tonight, not be discovered at restore time. The "snapshot
    # complete" success line only fires once verify is happy AND every
    # deployment's snapshot succeeded — otherwise we exit non-zero and the
    # backup runner aborts the run.
    local verify_rc=0
    if (( do_verify )); then
        verify_snapshot --out "$out" >/dev/null 2>&1 || verify_rc=$?
        if (( verify_rc != 0 )); then
            err "snapshot built at $out (${total_dur}s, $summary) but verify FAILED — DO NOT proceed with off-site backup"
            return 3
        fi
    fi

    if (( n_fail > 0 )); then
        err "snapshot built at $out (${total_dur}s, $summary) with $n_fail FAILED deployment(s) — inspect $out/snapshot.json"
        return 1
    fi

    info "snapshot complete: $out (${total_dur}s, $n_ok ok, $summary)"
    return 0
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

# Cheap structural check — does the bundle look intact?
verify_snapshot() {
    local out="$DEFAULT_OUT"
    while (( $# > 0 )); do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done

    [[ -d "$out" ]] || die "no bundle at $out"
    local fail=0
    _check_file() { [[ -f "$out/$1" ]] || { err "missing: $out/$1"; fail=$((fail+1)); }; }
    _check_file BUNDLE_VERSION
    _check_file snapshot.json
    _check_file fleet-manifest.json
    _check_file README.txt

    [[ -f "$out/BUNDLE_VERSION" ]] && {
        local v; v="$(cat "$out/BUNDLE_VERSION")"
        [[ "$v" == "$BUNDLE_VERSION" ]] \
            || { err "BUNDLE_VERSION '$v' does not match expected '$BUNDLE_VERSION'"; fail=$((fail+1)); }
    }

    if [[ -f "$out/fleet-manifest.json" ]]; then
        jq -e . "$out/fleet-manifest.json" >/dev/null \
            || { err "fleet-manifest.json is not valid JSON"; fail=$((fail+1)); }
    fi

    local d name vmeta sha actual
    if [[ -d "$out/deployments" ]]; then
        for d in "$out/deployments"/*/; do
            name="$(basename "${d%/}")"
            # Accept either tarball.tar or tarball.tar.gz (older bundles).
            if [[ ! -f "$d/tarball.tar" && ! -f "$d/tarball.tar.gz" ]]; then
                err "deployments/$name missing tarball.tar(.gz)"; fail=$((fail+1))
            fi
            for vmeta in "$d/volumes"/*.meta.json; do
                [[ -f "$vmeta" ]] || continue
                # Accept either extension; the meta.json sibling matches by stem.
                local stem="${vmeta%.meta.json}"
                local vtar=""
                if [[ -f "$stem.tar" ]];    then vtar="$stem.tar"
                elif [[ -f "$stem.tar.gz" ]]; then vtar="$stem.tar.gz"
                fi
                if [[ -z "$vtar" ]]; then
                    err "$vmeta references missing tar"; fail=$((fail+1)); continue
                fi
                sha="$(jq -r '.sha256' "$vmeta")"
                actual="$(sha256sum "$vtar" | cut -d' ' -f1)"
                [[ "$sha" == "$actual" ]] \
                    || { err "$vtar sha256 mismatch (meta:$sha actual:$actual)"; fail=$((fail+1)); }
            done
        done
    fi

    if (( fail == 0 )); then
        info "bundle OK: $out"
        return 0
    else
        err "bundle verify FAILED: $fail problem(s)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

list_snapshot() {
    local out="$DEFAULT_OUT"
    while (( $# > 0 )); do
        case "$1" in
            --out) out="$2"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done

    [[ -d "$out" ]] || die "no bundle at $out"
    local meta="$out/snapshot.json"
    if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
        [[ -f "$meta" ]] && cat "$meta" || echo '{}'
        return 0
    fi
    if [[ -f "$meta" ]]; then
        echo "bundle    : $out"
        jq -r '"generated : \(.finished_at // .started_at)
host      : \(.host)
duration  : \(.duration_seconds)s
size      : \(.size_bytes) bytes
ok        : \(.deployments_ok)
failed    : \(.deployments_failed)"' "$meta"
        echo "deployments:"
        jq -r '.results[] | "  \(.outcome | (.+":") | .[0:9] | . + (" " * (9 - length)) ) \(.deployment) (\(.duration_seconds)s)\(if .error then " — " + .error else "" end)"' "$meta"
    else
        warn "no snapshot.json at $meta"
    fi
}

# ---------------------------------------------------------------------------
# install-hook / uninstall-hook
# ---------------------------------------------------------------------------

# Generate the contents of the pre-backup hook script. Calls nelly's
# snapshot.sh directly (rather than $PATH `nelly`) so it works under cron
# / systemd / restic timers where $HOME and $PATH are minimal.
#
# The hook does `create` AND `verify` and exits non-zero if either fails.
# That way a corrupt bundle trips the backup runner's hard-fail tonight,
# not at restore time. The backup-side runner is responsible for treating
# any non-zero from run-parts as an abort + alert (e.g. ping healthchecks
# fail). Without that the bundle is regenerated silently.
_hook_script() {
    local nelly_bin="$NELLY_ROOT/bin/nelly"
    local out_dir="$DEFAULT_OUT"
    cat <<HOOK_EOF
#!/usr/bin/env bash
# Generated by \`nelly snapshot install-hook\`. Regenerates the nelly
# restore bundle at $out_dir right before the off-site backup runs.
#
# IMPORTANT: this script must run BEFORE the actual restic / borg
# invocation, and a non-zero exit must abort the run + alert. The bundle
# is the off-site backup's contract; a stale or corrupt bundle silently
# making it off-site is worse than a missed backup.
set -euo pipefail
exec "$nelly_bin" snapshot create --out "$out_dir" "\$@"
HOOK_EOF
}

install_hook() {
    local hook_dir="$DEFAULT_HOOK_DIR"
    local name="$DEFAULT_HOOK_NAME"
    while (( $# > 0 )); do
        case "$1" in
            --hook-dir) hook_dir="$2"; shift 2 ;;
            --name)     name="$2"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done

    if [[ ! -d "$hook_dir" ]]; then
        info "creating $hook_dir (may require sudo)"
        mkdir -p "$hook_dir" 2>/dev/null \
            || die "cannot create $hook_dir — try:  sudo mkdir -p '$hook_dir' && sudo chown root:root '$hook_dir'"
    fi

    local dest="$hook_dir/$name"
    if [[ -e "$dest" ]] && ! confirm "$dest exists; overwrite?"; then
        die "aborted"
    fi
    _hook_script > "$dest"
    chmod 0755 "$dest"
    info "installed hook: $dest"
    info "  → will run: $NELLY_ROOT/bin/nelly snapshot create --out $DEFAULT_OUT"
    info "  → (--no-verify can be passed via the hook args if you ever need to skip)"
    info "  → ensure your backup runner executes run-parts $hook_dir before each run,"
    info "    and treats a non-zero exit from any hook as ABORT + alert."

    # Best-effort: ensure the bundle dir exists with sane perms.
    if [[ ! -d "$DEFAULT_OUT" ]]; then
        warn "$DEFAULT_OUT does not exist yet — create it with:"
        warn "  sudo install -d -o $(id -un) -g $(id -gn) -m 0700 '$DEFAULT_OUT'"
    elif [[ "$(stat -c '%a' "$DEFAULT_OUT" 2>/dev/null)" != "700" ]]; then
        warn "$DEFAULT_OUT exists but is not mode 0700 — tighten with:"
        warn "  sudo chmod 700 '$DEFAULT_OUT'"
        warn "  (the bundle holds cleartext secrets between off-site runs)"
    fi
}

uninstall_hook() {
    local hook_dir="$DEFAULT_HOOK_DIR"
    local name="$DEFAULT_HOOK_NAME"
    while (( $# > 0 )); do
        case "$1" in
            --hook-dir) hook_dir="$2"; shift 2 ;;
            --name)     name="$2"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done
    local dest="$hook_dir/$name"
    if [[ -f "$dest" ]]; then
        rm -f "$dest"
        info "removed: $dest"
    else
        warn "no hook installed at $dest"
    fi
}

# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    sub="${1:-}"; shift || true
    case "$sub" in
        create)          create_snapshot   "$@" ;;
        verify)          verify_snapshot   "$@" ;;
        list|ls|status)  list_snapshot     "$@" ;;
        install-hook)    install_hook      "$@" ;;
        uninstall-hook)  uninstall_hook    "$@" ;;
        ""|-h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
fi
