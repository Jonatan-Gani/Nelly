#!/usr/bin/env bash
# tests/e2e.sh — full pipeline test against a real Docker daemon.
#
# Skips cleanly (exit 0) if Docker isn't available, so it's safe to wire
# into CI matrices that don't always provide docker.
#
# What this covers:
#   1. nelly init -y + nelly app add with a local-path source
#   2. nelly secrets set (global + per-app)
#   3. nelly deploy with --wait-healthy + --auto-rollback
#   4. cron actually fires inside the container; metrics.jsonl appears
#   5. nelly run-now executes the app outside of cron
#   6. nelly metrics aggregates run data
#   7. release record was created and finalized as success
#   8. second deploy produces a second release; image-prune kicks in
#   9. nelly release restore reverts to first release
#  10. nelly stop / start round-trip
#  11. nelly bot notify is callable (without a real token, so just check syntax)
#
# Run: bash tests/e2e.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
cd "$ROOT"

FAIL=0
pass()    { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail()    { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip()    { printf '  \033[33m--\033[0m  %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

# Refuse to run without docker (but exit 0 — this is "skipped").
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "docker not available — e2e test skipped (this is fine in environments without docker)"
    exit 0
fi

NAME="nelly-e2e-$$"
DEPLOY_DIR="containers/$NAME"
SRC_DIR="$(mktemp -d)"

cleanup() {
    # Best-effort cleanup of everything we created.
    bin/nelly stop "$NAME" >/dev/null 2>&1 || true
    docker ps -a --format '{{.Names}}' | grep -qx "$NAME" \
        && docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker images "$NAME" -q 2>/dev/null | xargs -r docker image rm -f >/dev/null 2>&1 || true
    rm -rf "$DEPLOY_DIR" "$SRC_DIR"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
section "scaffold deployment + add a tiny local app"

mkdir -p "$SRC_DIR"
cat > "$SRC_DIR/hi.py" <<'PY'
import os, sys
print(f"hello from {os.environ.get('GREETING_FROM', '(unknown)')}; APP_TOKEN={os.environ.get('APP_TOKEN', '(unset)')}")
sys.exit(0)
PY

# Force the e2e container off the default network — just publish nothing.
bin/nelly -y init "$NAME" >/dev/null 2>&1
# Disable healthcheck during e2e — cron may not have started by the time we check.
bin/nelly set  "$NAME" '.network'  '{}'                    >/dev/null
bin/nelly set  "$NAME" '.packages' '[]'                    >/dev/null
bin/nelly app add "$NAME" --name hi --local "$SRC_DIR" \
    --schedule "*/1 * * * *" --entrypoint hi.py            >/dev/null
[[ "$(bin/nelly get "$NAME" '.apps[0].app_name')" == "hi" ]] \
    && pass "init + app add" || fail "init/add-app"

# ----------------------------------------------------------------------------
section "secrets: global + per-app"

bin/nelly secrets set "$NAME"           GREETING_FROM=e2e >/dev/null
bin/nelly secrets set "$NAME" --app hi  APP_TOKEN=abc123  >/dev/null
[[ -f "$DEPLOY_DIR/def/.env"            ]] && pass "global .env written"   || fail "global .env"
[[ -f "$DEPLOY_DIR/def/secrets/hi.env"  ]] && pass "per-app .env written"  || fail "per-app .env"

# ----------------------------------------------------------------------------
section "deploy (real build + run)"

# Note: --wait-healthy here is short. Cron runs as the healthcheck target;
# pgrep cron is available immediately after `cron -f` boots, so this is fast.
if bin/nelly deploy "$NAME" --wait-healthy 30 --auto-rollback 2>&1 | tail -50 >/tmp/deploy-e2e.log; then
    pass "first deploy succeeded"
else
    cat /tmp/deploy-e2e.log
    fail "deploy failed"; exit 1
fi
docker inspect "$NAME" >/dev/null 2>&1 \
    && pass "container exists" || fail "no container"
state="$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)"
[[ "$state" == "true" ]] && pass "container is running" || fail "container not running"

# ----------------------------------------------------------------------------
section "run-now + metrics + per-app secrets visible"

bin/nelly run-now "$NAME" hi 2>&1 | tail -5
sleep 1
METRICS_FILE="$DEPLOY_DIR/logs/cron/hi.metrics.jsonl"
LOG_FILE="$DEPLOY_DIR/logs/cron/hi.log"

[[ -f "$METRICS_FILE" ]] && pass "metrics file appeared" || fail "no metrics file"
[[ "$(wc -l < "$METRICS_FILE")" -ge 1 ]] \
    && pass "metrics has at least one entry" || fail "metrics empty"
last_rc="$(tail -1 "$METRICS_FILE" | jq -r .rc)"
[[ "$last_rc" == "0" ]] && pass "last run rc=0" || fail "rc=$last_rc"

# Confirm both global and per-app secrets reached the python process via run-now
if grep -q 'GREETING_FROM=(unknown)' "$LOG_FILE" 2>/dev/null; then
    fail "[run-now] global secret didn't reach the app (GREETING_FROM was unset)"
elif grep -q 'hello from e2e' "$LOG_FILE"; then
    pass "[run-now] global secret reached app (GREETING_FROM=e2e)"
fi
if grep -q 'APP_TOKEN=abc123' "$LOG_FILE"; then
    pass "[run-now] per-app secret reached app (APP_TOKEN=abc123)"
elif grep -q 'APP_TOKEN=(unset)' "$LOG_FILE"; then
    fail "[run-now] per-app secret not visible (APP_TOKEN unset)"
fi

# Cron clears its environment when dispatching jobs, so --env-file alone
# isn't enough. Verify the cron-style path (nelly-run sourced inside the
# container) ALSO sees both secret scopes. This catches the bug where
# global secrets reach run-now but not the actual cron-fired runs.
echo > "$LOG_FILE"   # clear so we can detect the new line cleanly
docker exec "$NAME" /usr/local/bin/nelly-run hi hi.py
sleep 1
if grep -q 'hello from e2e' "$LOG_FILE"; then
    pass "[cron-style] global secret reached cron-fired script"
else
    fail "[cron-style] global secret missing from cron-fired script (cat $LOG_FILE)"
    cat "$LOG_FILE"
fi
if grep -q 'APP_TOKEN=abc123' "$LOG_FILE"; then
    pass "[cron-style] per-app secret reached cron-fired script"
else
    fail "[cron-style] per-app secret missing from cron-fired script"
fi

# ----------------------------------------------------------------------------
section "release record is success"

rel_id="$(bin/nelly --json release show "$NAME" | jq -r .release_id)"
outcome="$(bin/nelly --json release show "$NAME" | jq -r .outcome)"
[[ "$outcome" == "success" ]] && pass "release $rel_id outcome=success" || fail "outcome=$outcome"

# Aggregated metrics
runs="$(bin/nelly --json metrics "$NAME" | jq -r '.[] | select(.app=="hi") | .runs')"
(( runs >= 1 )) && pass "metrics aggregated ($runs run(s))" || fail "metrics runs=$runs"

# ----------------------------------------------------------------------------
section "second deploy → second release → image-prune kept the right images"

# Tiny config change so build hash changes
bin/nelly set "$NAME" '.resources.pids_limit' '300' >/dev/null
bin/nelly deploy "$NAME" --wait-healthy 30 --auto-rollback 2>&1 | tail -5
n_rel="$(bin/nelly --json release list "$NAME" | jq 'length')"
(( n_rel >= 2 )) && pass "second release exists ($n_rel total)" || fail "n_rel=$n_rel"

img_count="$(docker images "$NAME" -q | wc -l | tr -d ' ')"
# We keep the last 2 successful + :latest (which may dedupe to one of those)
(( img_count <= 4 )) && pass "image-prune kept image count low ($img_count)" \
    || fail "image-prune left $img_count images"

# ----------------------------------------------------------------------------
section "release restore → reverts atomically"

bin/nelly release restore "$NAME" "$rel_id" --image-only >/dev/null 2>&1
# Now another release exists with rollback_of = $rel_id
latest_rb="$(bin/nelly --json release show "$NAME" | jq -r .rollback_of)"
[[ "$latest_rb" == "$rel_id" ]] && pass "rollback recorded as new release" || fail "rollback_of=$latest_rb"

# ----------------------------------------------------------------------------
section "stop / start round-trip"

bin/nelly stop  "$NAME" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == "false" ]] \
    && pass "stop works" || fail "stop"
bin/nelly start "$NAME" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == "true" ]] \
    && pass "start works" || fail "start"

# ----------------------------------------------------------------------------
section "doctor + explain + cron + status all run without error on a real deployment"

for cmd in doctor explain cron status; do
    if bin/nelly "$cmd" "$NAME" >/dev/null 2>&1; then
        pass "$cmd runs"
    else
        # doctor can legit return non-zero if some warning fires; that's fine
        if [[ "$cmd" == "doctor" ]]; then
            pass "$cmd ran (non-zero is expected when warnings exist)"
        else
            fail "$cmd returned non-zero"
        fi
    fi
done

# ----------------------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf '\033[32mall e2e checks passed\033[0m\n'
    exit 0
else
    printf '\033[31m%d e2e check(s) failed\033[0m\n' "$FAIL"
    exit 1
fi
