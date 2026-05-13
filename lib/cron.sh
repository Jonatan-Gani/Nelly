#!/usr/bin/env bash
# lib/cron.sh — show what cron will actually run inside the container.
#
#   nelly cron <name>           the assembled crontab, with human descriptions
#   nelly cron <name> --next N  also print the next N run times per app
#                                (best-effort; needs python3 on the host)
set -euo pipefail
DEPLOY_DIR="$1"; shift
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

NEXT=0
while (( $# > 0 )); do
    case "$1" in
        --next) NEXT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

CONFIG="$DEPLOY_DIR/def/config.json"
[[ -f "$CONFIG" ]] || die "no config at $CONFIG"

_bold() { [[ -t 1 ]] && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"; }
_dim()  { [[ -t 1 ]] && printf '\033[2m%s\033[0m' "$1" || printf '%s' "$1"; }

# Translate a 5-field cron expression into English when the pattern is common.
# Falls back to the literal expression for anything tricky.
_describe() {
    local expr="$1"
    case "$expr" in
        '@yearly'|'@annually') echo "yearly (Jan 1 00:00)"; return ;;
        '@monthly')            echo "monthly (day 1 00:00)"; return ;;
        '@weekly')             echo "weekly (Sun 00:00)"; return ;;
        '@daily'|'@midnight')  echo "daily at 00:00"; return ;;
        '@hourly')             echo "every hour at :00"; return ;;
        '@reboot')             echo "at container boot"; return ;;
    esac

    local m h dom mon dow
    read -r m h dom mon dow <<<"$expr"

    # */N * * * *  → every N minutes
    if [[ "$m" =~ ^\*/([0-9]+)$ && "$h" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        echo "every ${BASH_REMATCH[1]} minute(s)"; return
    fi
    # 0 */N * * *  → every N hours
    if [[ "$m" == "0" && "$h" =~ ^\*/([0-9]+)$ && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        echo "every ${BASH_REMATCH[1]} hour(s) on the hour"; return
    fi
    # M H * * *    → daily at HH:MM
    if [[ "$m" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        printf 'daily at %02d:%02d\n' "$h" "$m"; return
    fi
    # M H * * D    → weekly
    if [[ "$m" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" =~ ^[0-9]+$ ]]; then
        local days=(Sun Mon Tue Wed Thu Fri Sat)
        printf 'weekly on %s at %02d:%02d\n' "${days[$dow]}" "$h" "$m"; return
    fi
    echo "$expr"
}

# Try to compute next run times using python3. Returns silently on failure.
_next_runs() {
    local expr="$1" n="$2"
    command -v python3 >/dev/null 2>&1 || { echo "(python3 not on host)"; return; }
    python3 - "$expr" "$n" <<'PY' 2>/dev/null || echo "(could not compute)"
import sys, datetime as dt
expr, n = sys.argv[1], int(sys.argv[2])
named = {"@yearly":"0 0 1 1 *","@annually":"0 0 1 1 *","@monthly":"0 0 1 * *",
         "@weekly":"0 0 * * 0","@daily":"0 0 * * *","@midnight":"0 0 * * *",
         "@hourly":"0 * * * *"}
expr = named.get(expr, expr)
fields = expr.split()
if len(fields) != 5:
    sys.exit(1)

def parse(field, lo, hi):
    out = set()
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, step = part.split("/"); step = int(step)
        if part == "*":
            rng = range(lo, hi + 1)
        elif "-" in part:
            a, b = part.split("-"); rng = range(int(a), int(b) + 1)
        else:
            v = int(part); rng = range(v, v + 1)
        for i, x in enumerate(rng):
            if i % step == 0:
                out.add(x)
    return out

try:
    mins = parse(fields[0], 0, 59)
    hrs  = parse(fields[1], 0, 23)
    doms = parse(fields[2], 1, 31)
    mons = parse(fields[3], 1, 12)
    dows = parse(fields[4], 0, 6)
except Exception:
    sys.exit(1)

now = dt.datetime.now().replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
count = 0
for _ in range(60 * 24 * 366):           # at most one year ahead
    if (now.minute in mins and now.hour in hrs and now.day in doms
            and now.month in mons and (now.weekday() + 1) % 7 in dows):
        print(now.strftime("%Y-%m-%d %H:%M"))
        count += 1
        if count >= n:
            break
    now += dt.timedelta(minutes=1)
PY
}

mapfile -t APPS < <(jq -c '.apps[]' "$CONFIG")

if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
    out='[]'
    for app in "${APPS[@]}"; do
        name="$(echo "$app" | jq -r '.app_name')"
        sched="$(echo "$app" | jq -r '.schedule // empty')"
        ep="$(echo "$app" | jq -r '.entrypoint // empty')"
        desc=""; nexts="[]"
        if [[ -n "$sched" ]]; then
            desc="$(_describe "$sched")"
            if (( NEXT > 0 )); then
                nexts="$(_next_runs "$sched" "$NEXT" | jq -R . | jq -s .)"
            fi
        fi
        entry="$(jq -nc \
            --arg name "$name" --arg sched "$sched" --arg ep "$ep" --arg desc "$desc" \
            --argjson nexts "$nexts" \
            '{app:$name, schedule:$sched, entrypoint:$ep, description:$desc, next_runs:$nexts}')"
        out="$(echo "$out" | jq --argjson e "$entry" '. + [$e]')"
    done
    echo "$out"
    exit 0
fi

if (( ${#APPS[@]} == 0 )); then
    info "no apps configured"
    exit 0
fi

echo
echo "$(_bold 'Scheduled apps')"
printf '%-18s %-22s %s\n' "APP" "SCHEDULE" "WHEN"
for app in "${APPS[@]}"; do
    name="$(echo "$app" | jq -r '.app_name')"
    sched="$(echo "$app" | jq -r '.schedule  // "(none)"')"
    ep="$(echo "$app" | jq -r '.entrypoint // "(none)"')"
    if [[ "$sched" == "(none)" || -z "$ep" || "$ep" == "(none)" ]]; then
        printf '%-18s %-22s %s\n' "$name" "(unscheduled)" "$(_dim '(no schedule/entrypoint)')"
        continue
    fi
    desc="$(_describe "$sched")"
    printf '%-18s %-22s %s\n' "$name" "$sched" "$desc"
    if (( NEXT > 0 )); then
        while IFS= read -r when; do
            [[ -z "$when" ]] && continue
            printf '%-18s %-22s %s\n' "" "" "  $(_dim "next ↦ $when")"
        done < <(_next_runs "$sched" "$NEXT")
    fi
done
