#!/usr/bin/env bash
# Delete log files older than retention_days (default 7).
set -euo pipefail

DEPLOY_DIR="$1"
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
DAYS="$(jqget "$CONFIG" '.log_retention_days' '7')"
LOG_DIR="$DEPLOY_DIR/logs"

[[ -d "$LOG_DIR" ]] || { info "no log dir; nothing to prune"; exit 0; }

info "pruning logs older than $DAYS days in $LOG_DIR"
find "$LOG_DIR" -type f \( -name '*.log' -o -name '*.metrics.jsonl' \) -mtime "+$DAYS" -print -delete
