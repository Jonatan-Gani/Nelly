#!/usr/bin/env bash
# Tail the deployment's cron output (or one app's log).
set -euo pipefail

DEPLOY_DIR="$1"
APP="${2:-}"
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

LOG_DIR="$DEPLOY_DIR/logs/cron"
if [[ -n "$APP" ]]; then
    f="$LOG_DIR/$APP.log"
    [[ -f "$f" ]] || die "no log for app $APP at $f"
    exec tail -F "$f"
fi

mapfile -t FILES < <(find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' 2>/dev/null)
[[ ${#FILES[@]} -gt 0 ]] || die "no logs yet in $LOG_DIR — has the container produced output?"
exec tail -F "${FILES[@]}"
