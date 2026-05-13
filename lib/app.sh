#!/usr/bin/env bash
# lib/app.sh — manage apps within a deployment.
#
# Subcommands (called from bin/nelly):
#   add       <dir> [--name N (--git URL [--ref R] | --local PATH)
#                    --schedule "..." --entrypoint FILE]
#             If any required flag is missing, runs the interactive wizard.
#   list      <dir>
#   show      <dir> <app>
#   remove    <dir> <app>
#   schedule  <dir> <app> "<cron>"
#   ref       <dir> <app> <git-ref>          # change source.ref for git apps
#   path      <dir> <app> <local-path>       # change source.path for local apps
set -euo pipefail

LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"
# shellcheck source=wizard.sh
source "$LIB/wizard.sh"

usage() {
    cat <<'EOF'
nelly app <sub> <name> [args...]

  add       <name>                                  interactive wizard
  add       <name> --name N --git URL [--ref R] --schedule "..." --entrypoint FILE
  add       <name> --name N --local PATH --schedule "..." --entrypoint FILE
  list      <name>
  show      <name> <app>
  remove    <name> <app>
  schedule  <name> <app> "<cron>"
  ref       <name> <app> <git-ref>
  path      <name> <app> <local-path>

`nelly add-app` and `nelly remove-app` are kept as aliases for `nelly app add`
and `nelly app remove`.
EOF
}

sub="${1:-}"; shift || true
DEPLOY_DIR="${1:-}"; shift || true
[[ -n "$sub" && -n "$DEPLOY_DIR" ]] || { usage; exit 2; }

config="$DEPLOY_DIR/def/config.json"
[[ -f "$config" ]] || die "no config at $config"

_app_exists() {
    [[ "$(jq --arg n "$1" '[.apps[] | select(.app_name==$n)] | length' "$config")" -gt 0 ]]
}
_app_index() {
    jq --arg n "$1" '.apps | map(.app_name) | index($n) // empty' "$config"
}

case "$sub" in

    add)
        # Either flag-driven (delegates to lib/config.sh add-app) or wizard.
        if (( $# == 0 )); then
            wizard_add_app "$DEPLOY_DIR"
        else
            # If any required flag is missing, fall back to the wizard.
            local_args=("$@")
            need_wizard=1
            for arg in "$@"; do
                case "$arg" in --name|--git|--local|--schedule|--entrypoint) need_wizard=0 ;; esac
            done
            if (( need_wizard )); then
                wizard_add_app "$DEPLOY_DIR"
            else
                "$LIB/config.sh" add-app "$DEPLOY_DIR" "${local_args[@]}"
            fi
        fi
        ;;

    list)
        if [[ "${NELLY_OUTPUT:-human}" == "json" ]]; then
            jq '.apps' "$config"
            exit 0
        fi
        if [[ "$(jq '.apps | length' "$config")" == "0" ]]; then
            info "no apps yet — try: nelly app add $(basename "$DEPLOY_DIR")"
            exit 0
        fi
        printf '%-20s %-10s %-30s %s\n' "APP" "SOURCE" "SCHEDULE" "ENTRYPOINT"
        jq -r '
            .apps[] |
            [
                .app_name,
                (.source.type // (if .git_url then "git" else "?" end)),
                (.schedule  // "(none)"),
                (.entrypoint // "(none)")
            ] | @tsv' "$config" | while IFS=$'\t' read -r n t s e; do
                printf '%-20s %-10s %-30s %s\n' "$n" "$t" "$s" "$e"
            done
        ;;

    show)
        name="${1:-}"
        [[ -n "$name" ]] || die "usage: app show <name> <app>"
        _app_exists "$name" || die "no such app: $name"
        jq --arg n "$name" '.apps[] | select(.app_name == $n)' "$config"
        ;;

    remove)
        name="${1:-}"
        [[ -n "$name" ]] || die "usage: app remove <name> <app>"
        _app_exists "$name" || die "no such app: $name"
        "$LIB/config.sh" remove-app "$DEPLOY_DIR" "$name"
        info "(takes effect on the next: nelly deploy $(basename "$DEPLOY_DIR"))"
        ;;

    schedule)
        name="${1:-}"; cron="${2:-}"
        [[ -n "$name" && -n "$cron" ]] || die "usage: app schedule <name> <app> \"<cron>\""
        _app_exists "$name" || die "no such app: $name"
        old="$(jq -r --arg n "$name" '.apps[] | select(.app_name==$n) | .schedule // "(none)"' "$config")"
        "$LIB/config.sh" set-schedule "$DEPLOY_DIR" "$name" "$cron"
        info "  was: $old"
        info "  now: $cron"
        info "(takes effect on the next: nelly deploy $(basename "$DEPLOY_DIR"))"
        ;;

    ref)
        name="${1:-}"; new_ref="${2:-}"
        [[ -n "$name" && -n "$new_ref" ]] || die "usage: app ref <name> <app> <git-ref>"
        idx="$(_app_index "$name")"
        [[ -n "$idx" ]] || die "no such app: $name"
        stype="$(jq -r ".apps[$idx].source.type // (if .apps[$idx].git_url then \"git\" else \"\" end)" "$config")"
        [[ "$stype" == "git" ]] || die "app '$name' is not a git source"
        old="$(jq -r ".apps[$idx].source.ref // .apps[$idx].ref // .apps[$idx].branch // \"\"" "$config")"
        jq_inplace "$config" --argjson i "$idx" --arg r "$new_ref" '
            if .apps[$i].source then .apps[$i].source.ref = $r
            else .apps[$i].ref = $r
            end'
        info "set ref for $name: $old → $new_ref"
        ;;

    path)
        name="${1:-}"; new_path="${2:-}"
        [[ -n "$name" && -n "$new_path" ]] || die "usage: app path <name> <app> <local-path>"
        [[ -d "$new_path" ]] || die "no such directory: $new_path"
        idx="$(_app_index "$name")"
        [[ -n "$idx" ]] || die "no such app: $name"
        stype="$(jq -r ".apps[$idx].source.type // \"\"" "$config")"
        [[ "$stype" == "local" ]] || die "app '$name' is not a local source"
        old="$(jq -r ".apps[$idx].source.path" "$config")"
        jq_inplace "$config" --argjson i "$idx" --arg p "$new_path" '.apps[$i].source.path = $p'
        info "set path for $name: $old → $new_path"
        ;;

    *) usage; exit 2 ;;
esac
