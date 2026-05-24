#!/usr/bin/env bash
# lib/metrics.sh — per-app run metrics, aggregated from /var/log/nelly/*.metrics.jsonl
#
# Each cron invocation appends one JSON line to <app>.metrics.jsonl via the
# small `nelly-run` wrapper baked into the container image. Lines look like:
#
#   {"ts":"2026-05-14T12:34:56Z","app":"fetcher","rc":0,"duration_s":12}
#
# Subcommands:
#   show <deploy_dir> [--app A] [--since DUR] [--release REL]
#
# DUR supports the form Ns | Nm | Nh | Nd. --release filters to a release's
# time window (between its created_at and the next release's created_at —
# or now if it's the latest).

set -euo pipefail
LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[[ "$(type -t info)" == "function" ]] || source "$LIB/common.sh"

DEPLOY_DIR="$1"; shift || true
[[ -d "$DEPLOY_DIR" ]] || die "not a deployment: $DEPLOY_DIR"

APP=""; SINCE=""; RELEASE=""
while (( $# > 0 )); do
    case "$1" in
        --app)     APP="$2";     shift 2 ;;
        --since)   SINCE="$2";   shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

METRICS_DIR="$DEPLOY_DIR/logs/cron"
mapfile -t FILES < <(find "$METRICS_DIR" -maxdepth 1 -type f -name '*.metrics.jsonl' 2>/dev/null)
if (( ${#FILES[@]} == 0 )); then
    if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then echo '[]'; else info "no metrics yet"; fi
    exit 0
fi

# Convert a duration like "24h" / "30m" / "7d" to seconds ago (epoch).
_since_to_epoch() {
    local s="$1"
    [[ -z "$s" ]] && { echo "0"; return; }
    local n="${s%[smhd]}" unit="${s: -1}"
    [[ "$n" =~ ^[0-9]+$ ]] || die "invalid --since: $s (use eg. 30m, 24h, 7d)"
    local mult
    case "$unit" in
        s) mult=1 ;;
        m) mult=60 ;;
        h) mult=3600 ;;
        d) mult=86400 ;;
        *) die "invalid --since unit: $unit (use s|m|h|d)" ;;
    esac
    echo $(( $(date +%s) - n * mult ))
}

START_EPOCH="$(_since_to_epoch "$SINCE")"
END_EPOCH="0"   # 0 = no upper bound

# --release: derive a time window from the index.
if [[ -n "$RELEASE" ]]; then
    idx="$DEPLOY_DIR/def/releases.index.json"
    [[ -f "$idx" ]] || die "no releases yet"
    START_EPOCH="$(jq -r --arg id "$RELEASE" '
        (.releases | map(select(.release_id == $id)) | first | .created_at) // empty
    ' "$idx")"
    [[ -n "$START_EPOCH" ]] || die "no such release: $RELEASE"
    START_EPOCH="$(date -ud "$START_EPOCH" +%s)"
    # End: next release's created_at, or open (0).
    END_EPOCH="$(jq -r --arg id "$RELEASE" '
        .releases as $all
        | ($all | map(.release_id) | index($id)) as $i
        | (if $i != null and $i + 1 < ($all|length) then $all[$i+1].created_at else "" end)
    ' "$idx")"
    if [[ -n "$END_EPOCH" ]]; then
        END_EPOCH="$(date -ud "$END_EPOCH" +%s)"
    else
        END_EPOCH="0"
    fi
fi

# Aggregate via jq. -R reads lines; jq has no JSONL primitive but `[inputs]`
# after `-Rn fromjson? // empty` works cleanly.
SUMMARY="$(
    cat "${FILES[@]}" \
    | jq -Rn --arg app "$APP" --argjson start "$START_EPOCH" --argjson end "$END_EPOCH" '
        [inputs | fromjson? // empty]
        | map(select($app == "" or .app == $app))
        | map(. + {epoch: (.ts | fromdateiso8601)})
        | map(select(.epoch >= $start))
        | (if $end > 0 then map(select(.epoch <= $end)) else . end)
        | group_by(.app) | map({
            app: .[0].app,
            runs:        length,
            success:     ([.[] | select(.rc == 0)] | length),
            failed:      ([.[] | select(.rc != 0)] | length),
            last_ts:     (max_by(.epoch).ts),
            last_rc:     (max_by(.epoch).rc),
            avg_dur_s:   ([.[].duration_s] | add / length | floor),
            max_dur_s:   ([.[].duration_s] | max),
            p95_dur_s:   ((sort_by(.duration_s) | .[((length * 95 / 100) | floor)] | .duration_s) // null)
        })
        | sort_by(.app)
    '
)"

if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
    echo "$SUMMARY"
    exit 0
fi

if [[ "$(echo "$SUMMARY" | jq 'length')" == "0" ]]; then
    info "no metrics matched the filter"
    exit 0
fi

# Pretty table
printf '%-16s %6s %6s %6s %8s %8s %22s %4s\n' \
    "APP" "RUNS" "OK" "FAIL" "AVG(s)" "P95(s)" "LAST" "RC"
echo "$SUMMARY" | jq -r '.[] |
    [.app, .runs, .success, .failed, .avg_dur_s, (.p95_dur_s // 0),
     .last_ts, .last_rc] | @tsv' \
    | while IFS=$'\t' read -r app runs ok fail avg p95 last rc; do
        printf '%-16s %6s %6s %6s %8s %8s %22s %4s\n' \
            "$app" "$runs" "$ok" "$fail" "$avg" "$p95" "$last" "$rc"
    done
