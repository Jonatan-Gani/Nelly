#!/usr/bin/env bash
# lib/check-updates.sh — watch the nelly source repo for new commits and
# (optionally) notify the operator via the Telegram bot.
#
# This is the polling half of "ask should I update?":
#   - a systemd user timer (install via `install-timer`) runs hourly
#   - on each tick it does `git fetch` + compares HEAD vs origin
#   - if behind, sends one Telegram message — and remembers the SHA, so
#     we don't re-spam the same commit every hour
#   - the operator replies in the bot with /update_check (preview) or
#     /update (apply). Those handlers shell back into the existing
#     `nelly update` pipeline (smoke test, redeploy if needed, etc).
#
# Branch policy: we check origin/$BRANCH where $BRANCH is the repo's
# currently-checked-out branch. That matches what `nelly update` will
# actually pull, so the preview and the apply agree. The `--branch`
# flag (or NELLY_UPDATE_BRANCH) overrides only the *check*, which is
# useful for "I'm on dev but tell me when main moves" — though in that
# case `nelly update` won't pull main; you'd have to switch first.
#
# Subcommands:
#   check                       Print status; exit 0 if up-to-date, 1 if
#                               behind, 2 on error.
#   check --notify              Same, plus send one Telegram message if
#                               behind. Idempotent — won't re-notify the
#                               same SHA twice in a row.
#   install-timer [--every D]   Install systemd --user timer that runs
#                               `check --notify` on a schedule (default 1h).
#   uninstall-timer
#   status                      Show whether the timer is installed +
#                               active, and what was last notified.
#
# Storage:
#   $NELLY_ROOT/.update-check.state    last-notified SHA (so we don't spam)

set -euo pipefail
LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=common.sh
[[ "$(type -t info)" == "function" ]] || source "$LIB/common.sh"

STATE_FILE="$NELLY_ROOT/.update-check.state"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_NAME="nelly-update-check.service"
TIMER_NAME="nelly-update-check.timer"

usage() {
    cat <<'EOF'
check-updates.sh check  [--notify] [--branch NAME]
check-updates.sh install-timer   [--every DURATION]
check-updates.sh uninstall-timer
check-updates.sh status
EOF
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_current_branch() {
    git -C "$NELLY_ROOT" symbolic-ref --short HEAD 2>/dev/null
}

_resolve_branch() {
    local b="${1:-}"
    if [[ -z "$b" ]]; then
        b="${NELLY_UPDATE_BRANCH:-$(_current_branch || true)}"
    fi
    [[ -n "$b" ]] || die "no branch to check (detached HEAD? set --branch or NELLY_UPDATE_BRANCH)"
    printf '%s' "$b"
}

_load_last_notified() {
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""
}

_save_last_notified() {
    printf '%s' "$1" > "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

do_check() {
    local notify=0 branch=""
    while (( $# > 0 )); do
        case "$1" in
            --notify)  notify=1; shift ;;
            --branch)  branch="$2"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done

    require_cmd git
    [[ -d "$NELLY_ROOT/.git" ]] || die "$NELLY_ROOT is not a git repo"

    branch="$(_resolve_branch "$branch")"

    # Fetch quietly. Network failure is a soft fail (exit 2) — the timer
    # will retry on its next tick; we don't want to spam Telegram with
    # transient errors.
    if ! git -C "$NELLY_ROOT" fetch --quiet origin "$branch" 2>/dev/null; then
        warn "git fetch failed for origin/$branch (network?)"
        return 2
    fi

    local local_sha remote_sha
    local_sha="$(git -C "$NELLY_ROOT" rev-parse HEAD)"
    remote_sha="$(git -C "$NELLY_ROOT" rev-parse "origin/$branch" 2>/dev/null || true)"
    [[ -n "$remote_sha" ]] || { warn "no upstream branch: origin/$branch"; return 2; }

    if [[ "$local_sha" == "$remote_sha" ]]; then
        info "up to date on $branch ($(git -C "$NELLY_ROOT" rev-parse --short HEAD))"
        return 0
    fi

    # Compute the diff in human terms.
    local n_commits log_summary
    n_commits="$(git -C "$NELLY_ROOT" rev-list --count "$local_sha".."$remote_sha")"
    log_summary="$(git -C "$NELLY_ROOT" log --oneline --no-decorate \
                       "$local_sha".."$remote_sha" 2>/dev/null | head -10)"

    info "behind on $branch by $n_commits commit(s):"
    printf '%s\n' "$log_summary" | sed 's/^/  /' >&2

    if (( notify )); then
        local last_notified; last_notified="$(_load_last_notified)"
        if [[ "$last_notified" == "$remote_sha" ]]; then
            info "already notified for $remote_sha — skipping"
        else
            _send_notification "$branch" "$local_sha" "$remote_sha" "$n_commits" "$log_summary" \
                && _save_last_notified "$remote_sha"
        fi
    fi
    return 1
}

_send_notification() {
    local branch="$1" local_sha="$2" remote_sha="$3" n="$4" log="$5"
    local short_remote; short_remote="$(git -C "$NELLY_ROOT" rev-parse --short "$remote_sha")"
    local short_local;  short_local="$(git -C "$NELLY_ROOT" rev-parse --short "$local_sha")"

    local msg
    msg="$(cat <<EOF
Nelly update available on $branch
$n commit(s) ahead — $short_local → $short_remote

$log

Reply /update_check for a preview, or /update to apply.
EOF
)"

    # Don't blow up if the bot isn't configured — log and move on so the
    # check itself still succeeds (the operator can still see status via
    # `nelly check-updates status`).
    if ! "$NELLY_ROOT/bin/nelly" bot notify "$msg" >/dev/null 2>&1; then
        warn "bot notify failed — is the bot configured? (nelly bot setup)"
        return 1
    fi
    info "notified bot about $short_remote"
}

# ---------------------------------------------------------------------------
# install-timer / uninstall-timer / status
# ---------------------------------------------------------------------------

do_install_timer() {
    local every="1h"
    while (( $# > 0 )); do
        case "$1" in
            --every) every="$2"; shift 2 ;;
            *) die "unknown flag: $1" ;;
        esac
    done

    command -v systemctl >/dev/null 2>&1 \
        || die "systemctl not found — this installer is systemd-only (use cron manually if you prefer)"

    mkdir -p "$SYSTEMD_DIR"
    local nelly_bin="$NELLY_ROOT/bin/nelly"

    cat > "$SYSTEMD_DIR/$SERVICE_NAME" <<UNIT
[Unit]
Description=Nelly: check for upstream updates and notify via Telegram bot
Documentation=https://github.com/Jonatan-Gani/Nelly

[Service]
Type=oneshot
ExecStart=$nelly_bin check-updates check --notify
# A failed check is not catastrophic — the next tick retries.
SuccessExitStatus=0 1
UNIT

    cat > "$SYSTEMD_DIR/$TIMER_NAME" <<UNIT
[Unit]
Description=Nelly: periodic upstream update check

[Timer]
OnBootSec=5min
OnUnitActiveSec=$every
RandomizedDelaySec=10min
Persistent=true
Unit=$SERVICE_NAME

[Install]
WantedBy=timers.target
UNIT

    systemctl --user daemon-reload
    systemctl --user enable --now "$TIMER_NAME"
    info "installed and started: $TIMER_NAME (every $every)"
    info "  → on each tick: $nelly_bin check-updates --notify"
    info "  → state file:   $STATE_FILE"
    info "view status: nelly check-updates status"
}

do_uninstall_timer() {
    command -v systemctl >/dev/null 2>&1 || die "systemctl not found"
    systemctl --user disable --now "$TIMER_NAME" 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/$TIMER_NAME" "$SYSTEMD_DIR/$SERVICE_NAME"
    systemctl --user daemon-reload 2>/dev/null || true
    info "uninstalled: $TIMER_NAME"
}

do_status() {
    if command -v systemctl >/dev/null 2>&1; then
        # Capture stdout and exit code separately. The fallback-via-||
        # pattern smushed two strings into one variable when systemctl
        # both printed output AND exited non-zero (e.g. "not-found").
        local loaded active next
        loaded="$(systemctl --user is-enabled "$TIMER_NAME" 2>/dev/null)" || loaded=""
        [[ -n "$loaded" ]] || loaded="not-installed"
        active="$(systemctl --user is-active  "$TIMER_NAME" 2>/dev/null)" || active=""
        [[ -n "$active" ]] || active="inactive"
        echo "timer    : $TIMER_NAME"
        echo "loaded   : $loaded"
        echo "active   : $active"
        if [[ "$loaded" != "not-installed" ]]; then
            next="$(systemctl --user list-timers --no-legend "$TIMER_NAME" 2>/dev/null \
                    | awk '{print $1, $2}')"
            if [[ -n "$next" ]]; then
                echo "next     : $next"
            fi
        fi
    fi
    echo "branch   : $(_current_branch || echo unknown)"
    echo "head     : $(git -C "$NELLY_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    local last; last="$(_load_last_notified)"
    if [[ -n "$last" ]]; then
        echo "notified : $(git -C "$NELLY_ROOT" rev-parse --short "$last" 2>/dev/null || echo "$last")"
    else
        echo "notified : (none yet)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    sub="${1:-check}"; shift || true
    case "$sub" in
        check)             do_check            "$@" ;;
        install-timer)     do_install_timer    "$@" ;;
        uninstall-timer)   do_uninstall_timer  "$@" ;;
        status)            do_status           "$@" ;;
        ""|-h|--help|help) usage ;;
        *) usage; exit 2 ;;
    esac
fi
