#!/usr/bin/env bash
# lib/update.sh — `nelly update` pipeline.
#
# Pulls the latest Nelly source from the tracking branch and applies it
# in the right order:
#   1. git fetch + show what's new
#   2. fail fast if anything looks wrong (uncommitted changes, detached HEAD,
#      no upstream)
#   3. git pull --ff-only
#   4. run the smoke suite as a sanity check — if it fails, abort with
#      instructions to revert
#   5. restart the Telegram bot daemon if lib/bot.{py,sh} changed AND
#      it's currently running
#   6. redeploy every deployment if lib/build.sh / source.sh / template
#      Dockerfile changed (those affect what gets baked into images)
#   7. re-run every deployment if lib/run.sh / manage.sh / hooks.sh /
#      secrets.sh changed (runtime flags, no rebuild)
#
# Steps 5–7 prompt before acting unless -y is passed.

set -euo pipefail
LIB="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
[[ "$(type -t info)" == "function" ]] || source "$LIB/common.sh"

CHECK_ONLY=0
while (( $# > 0 )); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        -h|--help)
            cat <<'EOF'
nelly update [--check]

Pulls the latest Nelly from the tracking branch and applies it:
  - runs tests/smoke.sh as a sanity check
  - restarts the Telegram bot if lib/bot.{py,sh} changed
  - redeploys each deployment if lib/build.sh / source.sh / template
    Dockerfile changed (image rebuild)
  - re-runs each deployment if lib/run.sh / manage.sh / hooks.sh /
    secrets.sh changed (no rebuild)

Flags:
  --check   print what would happen, change nothing
  -i        prompt before each potentially-destructive step
  -y        skip prompts (yes to everything)
EOF
            exit 0 ;;
        *) die "unknown flag: $1" ;;
    esac
done

cd "$NELLY_ROOT"

# -------- git state checks --------------------------------------------------

[[ -d .git ]] || die "$NELLY_ROOT is not a git repo"
branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
[[ -n "$branch" ]] || die "detached HEAD — check out a branch first"

if [[ -n "$(git status --porcelain)" ]]; then
    err "uncommitted changes in $NELLY_ROOT:"
    git status --short >&2
    die "commit, stash, or discard them before running nelly update"
fi

# -------- fetch + compute what's new ---------------------------------------

info "fetching origin/$branch"
git fetch --quiet origin "$branch" || die "git fetch failed (network?)"

old_sha="$(git rev-parse HEAD)"
new_sha="$(git rev-parse "origin/$branch" 2>/dev/null || true)"
[[ -n "$new_sha" ]] || die "no upstream branch tracked: origin/$branch"

if [[ "$old_sha" == "$new_sha" ]]; then
    info "already up to date ($(git rev-parse --short HEAD))"
    exit 0
fi

n_commits="$(git rev-list --count "$old_sha".."$new_sha")"
echo
info "$n_commits new commit(s) on $branch:"
git log --oneline --no-decorate "$old_sha".."$new_sha" | sed 's/^/  /'

mapfile -t changed_files < <(git diff --name-only "$old_sha" "$new_sha")
echo
info "${#changed_files[@]} file(s) changed"

# Classify the changes so we know what we need to act on.
bot_changed=0
build_changed=0
run_changed=0
for f in "${changed_files[@]}"; do
    case "$f" in
        lib/bot.py|lib/bot.sh)                      bot_changed=1 ;;
        lib/build.sh|lib/source.sh|containers/template/def/Dockerfile|containers/template/def/cron)
                                                    build_changed=1 ;;
        lib/run.sh|lib/manage.sh|lib/hooks.sh|lib/secrets.sh)
                                                    run_changed=1 ;;
    esac
done

# -------- check mode: report and exit --------------------------------------

if (( CHECK_ONLY )); then
    echo
    info "(check mode — no changes applied)"
    (( bot_changed ))                       && info "  would: restart bot daemon"
    (( build_changed ))                     && info "  would: redeploy all containers (image rebuild)"
    (( !build_changed && run_changed ))     && info "  would: re-run all containers (no rebuild)"
    (( !bot_changed && !build_changed && !run_changed )) \
                                            && info "  no action-worthy changes (docs / tests / CLI only)"
    exit 0
fi

# -------- pull --------------------------------------------------------------

echo
info "pulling"
git pull --ff-only --quiet origin "$branch" || die "git pull failed (non-fast-forward?)"
info "now at $(git rev-parse --short HEAD)"

# -------- smoke suite -------------------------------------------------------

echo
info "running smoke tests"
if ! bash tests/smoke.sh >/dev/null 2>&1; then
    err "smoke tests FAILED on the new code"
    err "your previous working commit was: $old_sha"
    err "to revert, run:"
    err "  cd $NELLY_ROOT && git reset --hard $old_sha"
    exit 1
fi
info "smoke tests passed"

# -------- restart bot if needed --------------------------------------------

if (( bot_changed )); then
    echo
    if systemctl --user is-active --quiet nelly-bot 2>/dev/null; then
        if confirm "lib/bot.* changed — restart the bot daemon now?"; then
            info "restarting bot"
            systemctl --user restart nelly-bot
        fi
    else
        info "lib/bot.* changed but the bot daemon isn't running — skipping"
    fi
fi

# -------- deployments to act on --------------------------------------------

mapfile -t deps < <(
    if [[ -d containers ]]; then
        find containers -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
            | grep -v '^template$' \
            | sort
    fi
)
n_deps=${#deps[@]}

if (( build_changed && n_deps > 0 )); then
    echo
    info "lib/build.sh or template Dockerfile changed — image rebuilds needed"
    if confirm "redeploy $n_deps deployment(s)?"; then
        rc_all=0
        for d in "${deps[@]}"; do
            info "==> deploying $d"
            if ! "$NELLY_ROOT/bin/nelly" deploy "$d" --wait-healthy 60 --auto-rollback; then
                warn "$d: deploy failed (continuing with next)"
                rc_all=1
            fi
        done
        (( rc_all == 0 )) && info "all deployments redeployed cleanly" \
                          || warn "one or more deployments had problems — see output above"
    fi
elif (( run_changed && n_deps > 0 )); then
    echo
    info "lib/run.sh / manage.sh / hooks.sh / secrets.sh changed — re-run only (no rebuild)"
    if confirm "re-run $n_deps container(s)?"; then
        for d in "${deps[@]}"; do
            info "==> re-running $d"
            "$NELLY_ROOT/bin/nelly" run "$d" || warn "$d: re-run failed"
        done
    fi
fi

echo
info "update complete: $(git rev-parse --short HEAD)"
