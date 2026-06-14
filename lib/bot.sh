#!/usr/bin/env bash
# lib/bot.sh — Telegram bot management.
#
# Subcommands:
#   setup            interactive: bot token + allowed user IDs + writes flag
#   start            run the bot daemon in the foreground (wrap in tmux/systemd)
#   status           is the daemon running? + tail of bot.log
#   notify <msg>     send a one-shot message to all allowed users
#   test             send "test from <host>" to confirm wiring
#   allow <user_id>  add a user id to allowed_users
#   revoke <user_id> remove a user id from allowed_users
#   install-systemd  generate a systemd user unit so the bot starts on boot
#
# State lives at <NELLY_ROOT>/bot/:
#   .token         the Telegram bot token, mode 0600
#   config.json    { allowed_users[], allow_writes, notify_chat_id }
#   bot.log        append-only audit + activity log
#
set -euo pipefail
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=wizard.sh
source "$LIB/wizard.sh"

BOT_DIR="$NELLY_ROOT/bot"
TOKEN_FILE="$BOT_DIR/.token"
CONFIG_FILE="$BOT_DIR/config.json"
LOG_FILE="$BOT_DIR/bot.log"
BOT_PY="$LIB/bot.py"

usage() {
    cat <<'EOF'
nelly bot <sub> [args...]
  setup                 interactive setup (token + allowed users + writes)
  start                 run the bot in the foreground
  status                is it running? + recent log tail
  notify <message>      send a one-shot message to all allowed users
  test                  send a "hello from <host>" message
  allow  <user_id>      add a Telegram user id to allowed_users
  revoke <user_id>      remove a Telegram user id
  install-systemd       write ~/.config/systemd/user/nelly-bot.service
EOF
}

_require_python3() {
    require_cmd python3
}

_ensure_state_dir() {
    mkdir -p "$BOT_DIR"
    chmod 700 "$BOT_DIR"
}

_load_token() {
    [[ -f "$TOKEN_FILE" ]] || die "no token — run: nelly bot setup"
    cat "$TOKEN_FILE"
}

# Send a message to one chat id. Uses curl; returns 0 on Telegram OK=true.
_tg_send() {
    local token="$1" chat_id="$2" text="$3"
    require_cmd curl
    local resp
    resp="$(curl -fsS --max-time 15 \
        -d chat_id="$chat_id" \
        --data-urlencode text="$text" \
        "https://api.telegram.org/bot${token}/sendMessage" 2>&1 || true)"
    if echo "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        return 0
    fi
    err "telegram api: $resp"
    return 1
}

# Hit Telegram getUpdates once and print recent (user_id, username) pairs.
_tg_recent_users() {
    local token="$1"
    require_cmd curl jq
    curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null \
      | jq -r '.result[]?.message.from | "\(.id)\t\(.username // .first_name // "?")"' \
      | sort -u
}

# ----------------------------------------------------------------------------
# setup wizard
# ----------------------------------------------------------------------------

bot_setup() {
    _ensure_state_dir
    _require_python3
    require_cmd curl jq

    cat >&2 <<'EOF'

Telegram bot setup
==================
You'll need:
  1. A bot token from @BotFather (https://t.me/BotFather → /newbot)
  2. Your Telegram user id (message @userinfobot to see it,
     or skip and let this wizard auto-detect after you message your bot)

EOF
    local token
    if [[ -f "$TOKEN_FILE" ]] && prompt_yes_no "Token already configured — keep it?" y; then
        token="$(_load_token)"
    else
        while true; do
            prompt_required "Bot token (from BotFather)?" token
            if [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
                break
            fi
            warn "that doesn't look like a Telegram bot token; try again"
        done
        umask 077
        printf '%s\n' "$token" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        info "token saved to $TOKEN_FILE (mode 0600)"
    fi

    # Verify with getMe
    local me_resp username bot_id
    me_resp="$(curl -fsS --max-time 10 "https://api.telegram.org/bot${token}/getMe" 2>&1 || true)"
    if ! echo "$me_resp" | jq -e '.ok == true' >/dev/null 2>&1; then
        die "Telegram getMe failed: $me_resp"
    fi
    username="$(echo "$me_resp" | jq -r '.result.username')"
    bot_id="$(echo "$me_resp" | jq -r '.result.id')"
    info "connected as @$username (id=$bot_id)"

    # Initialize config.json if absent
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo '{"allowed_users": [], "allow_writes": false, "notify_chat_id": null}' > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    fi

    # Add at least one allowed user
    local user_id=""
    if prompt_yes_no "Send your bot any message now, then let me auto-detect your user id?" y; then
        info "waiting up to 60s for a message from you to @$username …"
        local end=$(( $(date +%s) + 60 )) found=""
        while (( $(date +%s) < end )); do
            sleep 2
            mapfile -t lines < <(_tg_recent_users "$token")
            if (( ${#lines[@]} > 0 )); then
                found="${lines[0]}"
                break
            fi
        done
        if [[ -n "$found" ]]; then
            user_id="${found%%	*}"
            local who="${found##*	}"
            info "detected user: $who (id=$user_id)"
        else
            warn "no messages seen; you'll need to enter your user id manually"
        fi
    fi
    if [[ -z "$user_id" ]]; then
        while true; do
            prompt_required "Your Telegram user id (numeric)?" user_id
            [[ "$user_id" =~ ^[0-9]+$ ]] && break
            warn "must be a number"
        done
    fi
    bot_allow "$user_id"

    local allow_writes
    if prompt_yes_no "Allow write commands (start/stop/deploy/rollback from Telegram)?" n; then
        allow_writes="true"
    else
        allow_writes="false"
    fi
    jq_inplace "$CONFIG_FILE" --argjson aw "$allow_writes" '.allow_writes = $aw'

    info "config:"
    jq . "$CONFIG_FILE"

    # Smoke test: send a hello message
    if prompt_yes_no "Send a test message now?" y; then
        _tg_send "$token" "$user_id" "Nelly bot online on $(hostname). Try /help."
        info "test message sent"
    fi

    cat <<EOF

Setup done.

Run the bot:
  nelly bot start              # foreground (Ctrl-C to stop)
  nelly bot install-systemd    # background, restarts on crash/boot

Add more allowed users later:
  nelly bot allow <user_id>

Wire deploy notifications by adding to your hook scripts:
  nelly bot notify "✅ \$NELLY_DEPLOYMENT deployed as \$NELLY_IMAGE"
EOF
}

# ----------------------------------------------------------------------------
# lifecycle
# ----------------------------------------------------------------------------

bot_start() {
    _ensure_state_dir
    _require_python3
    [[ -f "$TOKEN_FILE" ]]  || die "not set up — run: nelly bot setup"
    [[ -f "$CONFIG_FILE" ]] || die "not set up — run: nelly bot setup"
    info "starting bot daemon (Ctrl-C to stop)"
    # Replace shell with python — process gets PID 1 of the cgroup, signals propagate.
    NELLY_ROOT="$NELLY_ROOT" exec python3 "$BOT_PY"
}

bot_status() {
    # Best-effort PID lookup. We rely on python3 + the bot script path as the unique signature.
    local pids
    pids="$(pgrep -af "python3 .*/lib/bot\\.py" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$pids" ]]; then
        info "bot running, PID(s): $pids"
    else
        warn "bot not running"
    fi
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "config:"
        jq -r '"  allowed_users: \(.allowed_users | join(", "))\n  allow_writes:  \(.allow_writes)"' "$CONFIG_FILE"
    fi
    if [[ -f "$LOG_FILE" ]]; then
        echo
        echo "recent activity (last 20 lines of bot.log):"
        tail -n 20 "$LOG_FILE" | sed 's/^/  /'
    fi
}

# ----------------------------------------------------------------------------
# notifications
# ----------------------------------------------------------------------------

bot_notify() {
    local msg="${1:-}"
    [[ -n "$msg" ]] || die "usage: nelly bot notify <message>"
    [[ -f "$TOKEN_FILE" && -f "$CONFIG_FILE" ]] || die "not set up — run: nelly bot setup"
    local token; token="$(_load_token)"

    # Recipients: notify_chat_id if set, else every allowed_users entry.
    local chat_ids
    chat_ids="$(jq -r 'if .notify_chat_id != null then [.notify_chat_id] else .allowed_users end | .[]' "$CONFIG_FILE")"
    [[ -n "$chat_ids" ]] || die "no recipients — run: nelly bot allow <user_id>"

    local fail=0
    while IFS= read -r cid; do
        _tg_send "$token" "$cid" "$msg" || fail=$((fail+1))
    done <<<"$chat_ids"
    if (( fail > 0 )); then
        warn "$fail recipient(s) failed"
        return 1
    fi
    info "sent to $(echo "$chat_ids" | wc -l | tr -d ' ') recipient(s)"
}

bot_test() {
    bot_notify "Nelly bot test from $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# ----------------------------------------------------------------------------
# user allow-list management
# ----------------------------------------------------------------------------

bot_allow() {
    local uid="${1:-}"
    [[ "$uid" =~ ^[0-9]+$ ]] || die "user id must be numeric, got: ${uid:-(missing)}"
    _ensure_state_dir
    [[ -f "$CONFIG_FILE" ]] || echo '{"allowed_users": [], "allow_writes": false, "notify_chat_id": null}' > "$CONFIG_FILE"
    jq_inplace "$CONFIG_FILE" --argjson uid "$uid" \
        '.allowed_users = ((.allowed_users // []) + [$uid] | unique)'
    chmod 600 "$CONFIG_FILE"
    info "allowed_users: $(jq -r '.allowed_users | join(", ")' "$CONFIG_FILE")"
}

bot_revoke() {
    local uid="${1:-}"
    [[ "$uid" =~ ^[0-9]+$ ]] || die "user id must be numeric, got: ${uid:-(missing)}"
    [[ -f "$CONFIG_FILE" ]] || die "no config yet"
    jq_inplace "$CONFIG_FILE" --argjson uid "$uid" \
        '.allowed_users = ((.allowed_users // []) - [$uid])'
    info "allowed_users: $(jq -r '.allowed_users | join(", ")' "$CONFIG_FILE")"
}

# ----------------------------------------------------------------------------
# systemd user unit
# ----------------------------------------------------------------------------

bot_install_systemd() {
    local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    local unit="$unit_dir/nelly-bot.service"
    mkdir -p "$unit_dir"
    cat > "$unit" <<EOF
[Unit]
Description=Nelly Telegram bot
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
Environment=NELLY_ROOT=$NELLY_ROOT
ExecStart=$NELLY_ROOT/bin/nelly bot start
Restart=on-failure
RestartSec=5
# Hardening (best-effort under user units)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=$NELLY_ROOT

[Install]
WantedBy=default.target
EOF
    chmod 644 "$unit"
    info "wrote $unit"
    cat <<EOF

Enable + start:
  systemctl --user daemon-reload
  systemctl --user enable --now nelly-bot
  systemctl --user status nelly-bot

For the bot to run after you log out, enable lingering:
  sudo loginctl enable-linger \$USER

Logs:
  journalctl --user -u nelly-bot -f
  tail -F $LOG_FILE
EOF
}

# ----------------------------------------------------------------------------
# dispatch
# ----------------------------------------------------------------------------

sub="${1:-}"; shift || true
case "$sub" in
    setup)           bot_setup ;;
    start)           bot_start ;;
    status)          bot_status ;;
    notify)          bot_notify "${*:-}" ;;
    test)            bot_test ;;
    allow)           bot_allow "${1:-}" ;;
    revoke)          bot_revoke "${1:-}" ;;
    install-systemd) bot_install_systemd ;;
    ""|help|-h|--help) usage ;;
    *) err "unknown bot sub: $sub"; usage; exit 2 ;;
esac
