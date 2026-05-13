#!/usr/bin/env bash
# lib/manage.sh — container lifecycle commands.
# Subcommands: start | stop | restart | exec | shell | run-now | inspect
set -euo pipefail

LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"

usage() {
    cat <<'EOF'
manage.sh <sub> <deploy_dir> [args...]
  start    <dir>
  stop     <dir>
  restart  <dir>
  exec     <dir> -- <cmd...>
  shell    <dir>
  run-now  <dir> <app_name>
  inspect  <dir>
EOF
}

sub="${1:-}"; shift || true
DEPLOY_DIR="${1:-}"; shift || true
[[ -n "$sub" && -n "$DEPLOY_DIR" ]] || { usage; exit 2; }
require_cmd docker jq

CN="$(container_name_for "$DEPLOY_DIR")"

case "$sub" in
    start)
        if ! docker inspect "$CN" >/dev/null 2>&1; then
            die "container $CN does not exist; run: nelly deploy $(basename "$DEPLOY_DIR")"
        fi
        docker start "$CN" >/dev/null
        info "started $CN"
        ;;
    stop)
        if docker inspect "$CN" >/dev/null 2>&1; then
            docker stop "$CN" >/dev/null
            info "stopped $CN"
        else
            warn "container $CN does not exist"
        fi
        ;;
    restart)
        if docker inspect "$CN" >/dev/null 2>&1; then
            docker restart "$CN" >/dev/null
            info "restarted $CN"
        else
            die "container $CN does not exist"
        fi
        ;;
    exec)
        # Remaining args, optionally after `--`, are the command.
        [[ "${1:-}" == "--" ]] && shift
        [[ $# -gt 0 ]] || die "usage: exec <dir> -- <cmd...>"
        exec docker exec -it "$CN" "$@"
        ;;
    shell)
        # Prefer bash; fall back to sh.
        if docker exec "$CN" command -v bash >/dev/null 2>&1; then
            exec docker exec -it "$CN" bash
        else
            exec docker exec -it "$CN" sh
        fi
        ;;
    run-now)
        APP="${1:-}"
        [[ -n "$APP" ]] || die "usage: run-now <dir> <app_name>"
        local_dir="/home/apps/$APP"
        venv="/opt/venvs/$APP/bin/python"
        # Resolve entrypoint from config.json
        ep="$(jq -r --arg n "$APP" '.apps[] | select(.app_name==$n) | .entrypoint // empty' "$DEPLOY_DIR/def/config.json")"
        [[ -n "$ep" ]] || die "app $APP has no entrypoint in config.json"
        info "running $APP/$ep in $CN"
        docker exec "$CN" /bin/bash -lc "cd $local_dir && $venv $ep"
        ;;
    inspect)
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
            docker inspect "$CN"
        else
            docker inspect "$CN" \
                | jq -r '.[0] | "name:    \(.Name)\nstate:   \(.State.Status)\nstarted: \(.State.StartedAt)\nimage:   \(.Config.Image)\nrestart: \(.HostConfig.RestartPolicy.Name)\nmemory:  \(.HostConfig.Memory)\ncpus:    \(.HostConfig.NanoCpus)\npids:    \(.HostConfig.PidsLimit)\nhealth:  \(.State.Health.Status // "n/a")"'
        fi
        ;;
    *)
        usage; exit 2 ;;
esac
