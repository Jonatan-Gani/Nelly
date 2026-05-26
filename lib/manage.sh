#!/usr/bin/env bash
# lib/manage.sh — container lifecycle.
# Subcommands: start | stop | restart | exec | shell | attach | run-now | top | inspect
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
  shell    <dir> [--app <app>]
  attach   <dir>                  attach to the container's stdout (Ctrl-p Ctrl-q to detach)
  run-now  <dir> <app_name>
  top      <dir>                  processes running inside the container
  inspect  <dir>
EOF
}

sub="${1:-}"; shift || true
DEPLOY_DIR="${1:-}"; shift || true
[[ -n "$sub" && -n "$DEPLOY_DIR" ]] || { usage; exit 2; }
require_cmd docker jq

CN="$(container_name_for "$DEPLOY_DIR")"

# Best-effort: is the container present? Is it running?
_present() { docker inspect "$CN" >/dev/null 2>&1; }
_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$CN" 2>/dev/null || echo false)" == "true" ]]; }

case "$sub" in

    start)
        _present || die "container $CN does not exist; run: nelly deploy $(basename "$DEPLOY_DIR")"
        docker start "$CN" >/dev/null
        info "started $CN"
        ;;

    stop)
        if _present; then
            docker stop "$CN" >/dev/null
            info "stopped $CN"
        else
            warn "container $CN does not exist"
        fi
        ;;

    restart)
        _present || die "container $CN does not exist"
        docker restart "$CN" >/dev/null
        info "restarted $CN"
        ;;

    exec)
        # `nelly exec <name> -- <cmd...>` — the `--` is optional.
        [[ "${1:-}" == "--" ]] && shift
        (( $# > 0 )) || die "usage: exec <dir> -- <cmd...>"
        _running || die "container $CN is not running"
        exec docker exec -it "$CN" "$@"
        ;;

    shell)
        # `nelly shell <name>`             — bash inside the container
        # `nelly shell <name> --app <app>` — also cd into the app's dir and
        #                                    use the app's virtualenv (python, pip).
        app=""
        while (( $# > 0 )); do
            case "$1" in
                --app) app="${2:-}"; shift 2 ;;
                *) shift ;;
            esac
        done
        _running || die "container $CN is not running"

        # Pick the shell available inside the image.
        sh_cmd="bash"
        docker exec "$CN" command -v bash >/dev/null 2>&1 || sh_cmd="sh"

        if [[ -z "$app" ]]; then
            exec docker exec -it "$CN" "$sh_cmd"
        fi

        # Validate the app exists in the deployment config.
        if ! jq -e --arg n "$app" '.apps[] | select(.app_name == $n)' \
                "$DEPLOY_DIR/def/config.json" >/dev/null 2>&1; then
            die "no such app in this deployment: $app"
        fi

        # Inside the container: cd into the app's dir, activate its venv, drop into a shell.
        # Setting VIRTUAL_ENV + prepending its bin to PATH gives the expected behavior
        # (python / pip resolve to the app's interpreter) without requiring `activate`.
        info "entering $CN as app '$app' (cwd=/home/apps/$app, venv=/opt/venvs/$app)"
        exec docker exec -it \
            -w "/home/apps/$app" \
            -e "VIRTUAL_ENV=/opt/venvs/$app" \
            -e "PATH=/opt/venvs/$app/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            -e "NELLY_APP=$app" \
            "$CN" "$sh_cmd"
        ;;

    attach)
        # Stream the container's stdout/stderr. Ctrl-p Ctrl-q is the standard
        # detach key; --sig-proxy=false avoids killing the container on Ctrl-C.
        _running || die "container $CN is not running"
        info "attaching to $CN — use Ctrl-p Ctrl-q to detach without killing it"
        exec docker attach --sig-proxy=false "$CN"
        ;;

    run-now)
        APP="${1:-}"
        [[ -n "$APP" ]] || die "usage: run-now <dir> <app_name>"
        _running || die "container $CN is not running"
        ep="$(jq -r --arg n "$APP" '.apps[] | select(.app_name==$n) | .entrypoint // empty' \
              "$DEPLOY_DIR/def/config.json")"
        [[ -n "$ep" ]] || die "app $APP has no entrypoint in config.json"
        # Defense-in-depth: validate_config already restricts these, but
        # re-check so this code path stays safe if config.json is edited
        # between validate and run.
        [[ "$ep" =~ ^[A-Za-z0-9_./-]+$ && "$ep" != /* && "$ep" != *..* ]] \
            || die "entrypoint '$ep' contains unsafe characters; refusing to run"
        [[ "$APP" =~ ^[A-Za-z0-9_-]+$ ]] \
            || die "invalid app name; refusing to run"
        info "running $APP/$ep in $CN"

        # Route through the in-container nelly-run wrapper so behavior is
        # identical to a cron-fired invocation: per-app + global secrets
        # sourced, output appended to /var/log/nelly/<app>.log, metrics
        # entry appended to <app>.metrics.jsonl, log files rotated at the
        # configured size.
        log_path="/var/log/nelly/$APP.log"
        # Note size of the log before so we can tail just the new bytes
        # back to the user's terminal (stdout). `stat -c %s` is in procps.
        pre_size="$(docker exec "$CN" stat -c %s "$log_path" 2>/dev/null || echo 0)"
        rc=0
        docker exec "$CN" /usr/local/bin/nelly-run "$APP" "$ep" || rc=$?
        post_size="$(docker exec "$CN" stat -c %s "$log_path" 2>/dev/null || echo 0)"
        # Show what got appended this run.
        if (( post_size > pre_size )); then
            new_bytes=$((post_size - pre_size))
            docker exec "$CN" tail -c "$new_bytes" "$log_path"
        fi
        exit $rc
        ;;

    top)
        _running || die "container $CN is not running"
        docker top "$CN"
        ;;

    inspect)
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
            docker inspect "$CN"
        else
            docker inspect "$CN" | jq -r '.[0] |
                "name:     \(.Name)\n" +
                "state:    \(.State.Status)\n" +
                "started:  \(.State.StartedAt)\n" +
                "image:    \(.Config.Image)\n" +
                "restart:  \(.HostConfig.RestartPolicy.Name)\n" +
                "memory:   \(.HostConfig.Memory)\n" +
                "cpu(nano):\(.HostConfig.NanoCpus)\n" +
                "pids:     \(.HostConfig.PidsLimit)\n" +
                "health:   \(.State.Health.Status // "n/a")\n" +
                "networks: \([.NetworkSettings.Networks | keys[]] | join(", "))"'
        fi
        ;;

    *) usage; exit 2 ;;
esac
