#!/usr/bin/env bash
# lib/release.sh — release records: every `nelly deploy` produces one.
#
# A release captures the full snapshot needed to revert: image tag, config,
# commit pins, outcome, timings, and a copy of the build + run logs.
#
# Storage layout (per deployment):
#   def/releases.index.json                 ordered list + next_seq
#   def/releases/<rel_id>/manifest.json     metadata (see schema below)
#   def/releases/<rel_id>/config.json       config snapshot at deploy time
#   def/releases/<rel_id>/commits.lock.json lockfile snapshot
#   def/releases/<rel_id>/build.log         copied from logs/build.log
#   def/releases/<rel_id>/run.log           copied from logs/run.log
#
# Subcommands:
#   create   <deploy_dir>                          → echoes new release_id
#   finalize <deploy_dir> <rel_id> --outcome S [--image I] [--health H]
#                                                  [--auto-rolled-back B]
#                                                  [--rollback-of R]
#   list     <deploy_dir>                          table (or --json)
#   show     <deploy_dir> [rel_id]                 manifest pretty-print
#   diff     <deploy_dir> <rel_a> <rel_b>          config diff
#   restore  <deploy_dir> <rel_id> [--image-only|--config-only]
#                                                  recreates a release of its own
#   note     <deploy_dir> <rel_id> "<text>"
#   prune    <deploy_dir> [--keep N]               default 50

set -euo pipefail
LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=common.sh
[[ "$(type -t info)" == "function" ]] || source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

DEFAULT_KEEP=50

_releases_dir()  { printf '%s' "$1/def/releases"; }
_index_file()    { printf '%s' "$1/def/releases.index.json"; }
_ensure_index() {
    local deploy_dir="$1"
    local idx; idx="$(_index_file "$deploy_dir")"
    [[ -f "$idx" ]] || echo '{"next_seq": 1, "releases": []}' > "$idx"
}

_actor() {
    local user host
    user="${USER:-$(id -un 2>/dev/null || echo unknown)}"
    host="$(hostname 2>/dev/null || echo unknown)"
    printf '%s@%s' "$user" "$host"
}

# Find the release_id with the latest finalized_at; '' if none.
_latest_release() {
    local idx; idx="$(_index_file "$1")"
    [[ -f "$idx" ]] || { echo ""; return; }
    jq -r '.releases | map(select(.outcome != "pending"))
                     | sort_by(.finalized_at // .created_at)
                     | last | .release_id // ""' "$idx"
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

create_release() {
    local deploy_dir="$1"
    local config="$deploy_dir/def/config.json"
    [[ -f "$config" ]] || die "no config at $config"
    _ensure_index "$deploy_dir"

    local idx; idx="$(_index_file "$deploy_dir")"
    local seq; seq="$(jq -r '.next_seq' "$idx")"
    local rel_id; rel_id="$(printf 'r-%04d' "$seq")"
    local dir; dir="$(_releases_dir "$deploy_dir")/$rel_id"
    mkdir -p "$dir"

    # Snapshot config + lockfile right now.
    cp "$config" "$dir/config.json"
    [[ -f "$deploy_dir/def/commits.lock.json" ]] \
        && cp "$deploy_dir/def/commits.lock.json" "$dir/commits.lock.json" \
        || echo '{}' > "$dir/commits.lock.json"

    local prev; prev="$(_latest_release "$deploy_dir")"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local config_hash; config_hash="sha256:$(sha256sum "$config" | cut -d' ' -f1)"

    jq -n \
        --arg id "$rel_id" \
        --arg dep "$(basename "$deploy_dir")" \
        --arg created "$now" \
        --arg actor "$(_actor)" \
        --arg hash "$config_hash" \
        --arg prev "$prev" \
        '{
            release_id: $id,
            deployment: $dep,
            created_at: $created,
            finalized_at: null,
            duration_seconds: null,
            outcome: "pending",
            image: null,
            actor: $actor,
            config_hash: $hash,
            previous_release_id: (if $prev == "" then null else $prev end),
            rollback_of: null,
            health_status: null,
            wait_healthy_seconds: null,
            auto_rollback_triggered: false,
            note: ""
        }' > "$dir/manifest.json"

    # Add to index
    jq_inplace "$idx" --arg id "$rel_id" --arg created "$now" \
        '.releases += [{release_id: $id, created_at: $created, outcome: "pending"}]
       | .next_seq = (.next_seq + 1)'

    printf '%s' "$rel_id"
}

# ---------------------------------------------------------------------------
# finalize
# ---------------------------------------------------------------------------

finalize_release() {
    local deploy_dir="$1" rel_id="$2"; shift 2
    local outcome="" image="" health="" wait_s="" rollback_of="" auto_rb="false"
    while (( $# > 0 )); do
        case "$1" in
            --outcome)           outcome="$2";          shift 2 ;;
            --image)             image="$2";            shift 2 ;;
            --health)            health="$2";           shift 2 ;;
            --wait-healthy)      wait_s="$2";           shift 2 ;;
            --rollback-of)       rollback_of="$2";      shift 2 ;;
            --auto-rolled-back)  auto_rb="true";        shift ;;
            *) shift ;;
        esac
    done
    [[ -n "$outcome" ]] || die "finalize: --outcome required"

    local dir; dir="$(_releases_dir "$deploy_dir")/$rel_id"
    local manifest="$dir/manifest.json"
    [[ -f "$manifest" ]] || die "no such release: $rel_id"

    # Image fallback: read def/last_image.txt
    [[ -z "$image" && -f "$deploy_dir/def/last_image.txt" ]] \
        && image="$(cat "$deploy_dir/def/last_image.txt")"

    local now created
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    created="$(jq -r '.created_at' "$manifest")"
    local dur
    dur="$(( $(date -ud "$now" +%s) - $(date -ud "$created" +%s) ))"

    jq_inplace "$manifest" \
        --arg now "$now" \
        --arg outcome "$outcome" \
        --arg image "${image:-}" \
        --arg health "${health:-}" \
        --arg wait "${wait_s:-}" \
        --arg rb "${rollback_of:-}" \
        --argjson auto "$auto_rb" \
        --argjson dur "$dur" \
        '.finalized_at = $now
       | .outcome = $outcome
       | .image = (if $image  == "" then null else $image  end)
       | .health_status = (if $health == "" then null else $health end)
       | .wait_healthy_seconds = (if $wait == "" then null else ($wait | tonumber? // null) end)
       | .rollback_of = (if $rb == "" then null else $rb end)
       | .auto_rollback_triggered = $auto
       | .duration_seconds = $dur'

    # Snapshot the build/run logs that just happened (best-effort).
    for src in build run; do
        local from="$deploy_dir/logs/$src.log"
        [[ -f "$from" ]] && cp "$from" "$dir/$src.log"
    done

    # Update index entry
    jq_inplace "$(_index_file "$deploy_dir")" \
        --arg id "$rel_id" --arg out "$outcome" --arg fin "$now" \
        '.releases |= map(if .release_id == $id
                          then . + {outcome: $out, finalized_at: $fin}
                          else . end)'

    # Prune to retention window
    prune_releases "$deploy_dir" "$DEFAULT_KEEP" >/dev/null 2>&1 || true

    info "release $rel_id → $outcome (duration ${dur}s)"
}

# ---------------------------------------------------------------------------
# list / show / diff
# ---------------------------------------------------------------------------

list_releases() {
    local deploy_dir="$1"
    local idx; idx="$(_index_file "$deploy_dir")"
    if [[ ! -f "$idx" ]]; then
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then echo '[]'; else info "no releases yet"; fi
        return 0
    fi
    if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
        jq '.releases' "$idx"
        return 0
    fi
    printf '%-8s %-22s %-13s %s\n' "ID" "WHEN (UTC)" "OUTCOME" "IMAGE"
    jq -r '.releases | reverse | .[] |
        [.release_id,
         (.finalized_at // .created_at),
         .outcome,
         (.image // "(none)")] | @tsv' "$idx" \
        | while IFS=$'\t' read -r id when outcome image; do
            printf '%-8s %-22s %-13s %s\n' "$id" "$when" "$outcome" "$image"
        done
}

show_release() {
    local deploy_dir="$1" rel_id="${2:-}"
    [[ -n "$rel_id" ]] || rel_id="$(_latest_release "$deploy_dir")"
    [[ -n "$rel_id" ]] || die "no releases yet"
    local m="$(_releases_dir "$deploy_dir")/$rel_id/manifest.json"
    [[ -f "$m" ]] || die "no such release: $rel_id"
    if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
        jq . "$m"
        return 0
    fi
    jq -r '"release      : \(.release_id)
deployment  : \(.deployment)
outcome     : \(.outcome)
created     : \(.created_at)
finalized   : \(.finalized_at // "(pending)")
duration_s  : \(.duration_seconds // "(n/a)")
image       : \(.image // "(none)")
actor       : \(.actor)
config_hash : \(.config_hash)
previous    : \(.previous_release_id // "(none)")
rollback_of : \(.rollback_of // "(n/a)")
health      : \(.health_status // "(not waited)")
wait_s      : \(.wait_healthy_seconds // "(n/a)")
auto_rolled : \(.auto_rollback_triggered)
note        : \(.note)"' "$m"
}

diff_releases() {
    local deploy_dir="$1" a="$2" b="$3"
    local ca="$(_releases_dir "$deploy_dir")/$a/config.json"
    local cb="$(_releases_dir "$deploy_dir")/$b/config.json"
    [[ -f "$ca" ]] || die "no such release: $a"
    [[ -f "$cb" ]] || die "no such release: $b"
    if command -v diff >/dev/null 2>&1; then
        diff -u <(jq -S . "$ca") <(jq -S . "$cb") || true
    else
        echo "$a:"; jq -S . "$ca"
        echo "$b:"; jq -S . "$cb"
    fi
}

# ---------------------------------------------------------------------------
# restore (config + image)
# ---------------------------------------------------------------------------

restore_release() {
    local deploy_dir="$1" rel_id="$2"; shift 2
    local mode="both"
    while (( $# > 0 )); do
        case "$1" in
            --image-only)  mode="image"; shift ;;
            --config-only) mode="config"; shift ;;
            *) shift ;;
        esac
    done
    local dir="$(_releases_dir "$deploy_dir")/$rel_id"
    [[ -f "$dir/manifest.json" ]] || die "no such release: $rel_id"

    local image
    image="$(jq -r '.image // empty' "$dir/manifest.json")"

    if [[ "$mode" == "both" || "$mode" == "config" ]]; then
        if [[ -f "$dir/config.json" ]]; then
            cp "$dir/config.json" "$deploy_dir/def/config.json"
            info "restored config.json from $rel_id"
        fi
        if [[ -f "$dir/commits.lock.json" ]]; then
            cp "$dir/commits.lock.json" "$deploy_dir/def/commits.lock.json"
            info "restored commits.lock.json from $rel_id"
        fi
        validate_config "$deploy_dir" >/dev/null
    fi

    if [[ "$mode" == "both" || "$mode" == "image" ]]; then
        if [[ -n "$image" ]]; then
            # Have lib/run.sh swap the container to this image, and open a new
            # release record that points back at the one we're restoring.
            local new_id
            new_id="$(create_release "$deploy_dir")"
            if "$LIB/run.sh" "$deploy_dir" --image "$image"; then
                echo "$image" > "$deploy_dir/def/last_image.txt"
                finalize_release "$deploy_dir" "$new_id" \
                    --outcome rolled_back --image "$image" --rollback-of "$rel_id"
                info "now running $image (new release: $new_id)"
            else
                finalize_release "$deploy_dir" "$new_id" --outcome failed
                die "failed to start image $image"
            fi
        else
            warn "release $rel_id has no recorded image; only config restored"
        fi
    fi
}

# ---------------------------------------------------------------------------
# note / prune
# ---------------------------------------------------------------------------

note_release() {
    local deploy_dir="$1" rel_id="$2" text="$3"
    local m="$(_releases_dir "$deploy_dir")/$rel_id/manifest.json"
    [[ -f "$m" ]] || die "no such release: $rel_id"
    jq_inplace "$m" --arg t "$text" '.note = $t'
    info "set note on $rel_id"
}

prune_releases() {
    local deploy_dir="$1"; shift || true
    local keep="$DEFAULT_KEEP"
    while (( $# > 0 )); do
        case "$1" in
            --keep) keep="$2"; shift 2 ;;
            *) keep="$1"; shift ;;     # positional fallback
        esac
    done
    local idx="$(_index_file "$deploy_dir")"
    [[ -f "$idx" ]] || return 0
    local total; total="$(jq '.releases | length' "$idx")"
    (( total > keep )) || return 0
    local n_del=$((total - keep))
    # Oldest entries are at the front of the array; remove their dirs.
    mapfile -t to_drop < <(jq -r --argjson n "$n_del" '.releases[:$n] | .[].release_id' "$idx")
    for rid in "${to_drop[@]}"; do
        rm -rf "$(_releases_dir "$deploy_dir")/$rid"
    done
    jq_inplace "$idx" --argjson n "$n_del" '.releases = .releases[$n:]'
    info "pruned $n_del old release(s); kept $keep"
}

# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    sub="${1:-}"; shift || true
    case "$sub" in
        create)   create_release   "$@" ;;
        finalize) finalize_release "$@" ;;
        list|ls)  list_releases    "$@" ;;
        show)     show_release     "$@" ;;
        diff)     diff_releases    "$@" ;;
        restore)  restore_release  "$@" ;;
        note)     note_release     "$@" ;;
        prune)    prune_releases   "$@" ;;
        *) die "usage: release.sh {create|finalize|list|show|diff|restore|note|prune} ..." ;;
    esac
fi
