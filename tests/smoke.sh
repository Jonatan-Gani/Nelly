#!/usr/bin/env bash
# tests/smoke.sh — offline checks. Runs without Docker.
#
# Coverage:
#   - syntax (bash -n) + optional shellcheck
#   - intro and help text render
#   - `init -y` scaffolds + validates
#   - `app add/list/remove/schedule` round-trip (flag-driven, no wizard)
#   - `set` / `get` round-trip; JSON-typed values
#   - `secrets set/list/unset` round-trip; .env mode 0600
#   - invalid configs are rejected (bad cron, bad image name)
#   - explain + doctor exit cleanly
#   - list --json includes the new deployment

set -euo pipefail
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
cd "$ROOT"

FAIL=0
pass()    { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail()    { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
section() { printf '\n== %s ==\n' "$*"; }

# ----------------------------------------------------------------------------
section "bash syntax"
for f in bin/nelly lib/*.sh; do
    if bash -n "$f" 2>/tmp/nelly.synerr; then
        pass "syntax: $f"
    else
        fail "syntax: $f"
        cat /tmp/nelly.synerr
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    section "shellcheck"
    if shellcheck -x -S warning bin/nelly lib/*.sh tests/smoke.sh; then
        pass "shellcheck clean"
    else
        fail "shellcheck reported issues (warning+)"
    fi
fi

# ----------------------------------------------------------------------------
section "intro + help"
if bin/nelly 2>&1 | grep -q "First time?"; then pass "intro renders"; else fail "intro missing"; fi
if bin/nelly help >/dev/null 2>&1; then pass "help renders"; else fail "help"; fi
if bin/nelly help deploy >/dev/null 2>&1; then pass "help deploy"; else fail "help deploy"; fi
if bin/nelly help app >/dev/null 2>&1; then pass "help app"; else fail "help app"; fi

# ----------------------------------------------------------------------------
section "init (non-interactive) → validate"
NAME="smoketest-$$"
DIR="containers/$NAME"
trap 'rm -rf "$DIR"' EXIT

# -y means "auto-accept defaults; no app prompts"
bin/nelly -y init "$NAME" >/dev/null 2>&1
[[ -f "$DIR/def/config.json" ]] && pass "init created config.json" || fail "init missing config.json"
bin/nelly validate "$NAME" >/dev/null 2>&1 && pass "default config validates" || fail "default config invalid"

cn="$(bin/nelly get "$NAME" '.container_name')"
[[ "$cn" == "$NAME" ]] && pass "init sets container_name=$NAME" || fail "container_name=$cn"

# After init, no apps yet (wizard's default skipped).
n_apps="$(bin/nelly get "$NAME" '.apps | length')"
[[ "$n_apps" == "0" ]] && pass "init starts with zero apps" || fail "init left $n_apps apps in config"

# ----------------------------------------------------------------------------
section "app subcommand"
bin/nelly app add "$NAME" \
    --name foo --local /tmp \
    --schedule "*/5 * * * *" --entrypoint main.py >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="foo")] | length')" == "1" ]] \
    && pass "app add (flag-driven)" || fail "app add failed"

bin/nelly app list "$NAME" | grep -q "^foo" \
    && pass "app list shows foo" || fail "app list output: $(bin/nelly app list "$NAME")"

bin/nelly app show "$NAME" foo | jq -e '.entrypoint == "main.py"' >/dev/null \
    && pass "app show returns json" || fail "app show output"

bin/nelly app schedule "$NAME" foo "0 9 * * *" >/dev/null
sched="$(bin/nelly get "$NAME" '.apps[] | select(.app_name=="foo") | .schedule')"
[[ "$sched" == "0 9 * * *" ]] && pass "app schedule" || fail "schedule=$sched"

bin/nelly app path "$NAME" foo "/var/tmp" >/dev/null
new_path="$(bin/nelly get "$NAME" '.apps[] | select(.app_name=="foo") | .source.path')"
[[ "$new_path" == "/var/tmp" ]] && pass "app path" || fail "path=$new_path"

bin/nelly app remove "$NAME" foo >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="foo")] | length')" == "0" ]] \
    && pass "app remove" || fail "app remove failed"

# legacy aliases still work
bin/nelly add-app "$NAME" --name legacy --local /tmp --schedule "@daily" --entrypoint x.py >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="legacy")] | length')" == "1" ]] \
    && pass "legacy 'add-app' alias works" || fail "alias add-app"
bin/nelly remove-app "$NAME" legacy >/dev/null

# ----------------------------------------------------------------------------
section "set / get roundtrip"
bin/nelly set "$NAME" '.resources.cpus' '2.0' >/dev/null
cpus="$(bin/nelly get "$NAME" '.resources.cpus')"
[[ "$cpus" == "2.0" ]] && pass "set/get .resources.cpus" || fail "got $cpus"

bin/nelly set "$NAME" '.resources.pids_limit' '512' >/dev/null
pids="$(bin/nelly get "$NAME" '.resources.pids_limit')"
[[ "$pids" == "512" ]] && pass "JSON-typed set (number)" || fail "got $pids"

# ----------------------------------------------------------------------------
section "secrets"
bin/nelly secrets set "$NAME" FOO=bar BAZ='quoted "value"' >/dev/null
mode="$(stat -c %a "$DIR/def/.env")"
[[ "$mode" == "600" ]] && pass ".env mode 0600" || fail ".env mode is $mode"
keys="$(bin/nelly secrets list "$NAME" | sort | tr '\n' ' ')"
[[ "$keys" == "BAZ FOO " ]] && pass "secrets list keys only" || fail "got: $keys"
bin/nelly secrets unset "$NAME" FOO >/dev/null
remaining="$(bin/nelly secrets list "$NAME")"
[[ "$remaining" == "BAZ" ]] && pass "secrets unset" || fail "got: $remaining"

# ----------------------------------------------------------------------------
section "invalid configs are rejected"
if bin/nelly app add "$NAME" --name bad --local /tmp --schedule "not a cron" --entrypoint m.py >/dev/null 2>&1; then
    fail "accepted bad cron expression"
else
    pass "rejected bad cron"
fi
if bin/nelly set "$NAME" '.image_name' 'BAD NAME' >/dev/null 2>&1; then
    fail "accepted bad image name"
else
    pass "rejected bad image name"
fi

# ----------------------------------------------------------------------------
section "explain (works on empty + populated configs)"
bin/nelly explain "$NAME" >/dev/null 2>&1 \
    && pass "explain runs on empty config" || fail "explain failed"

bin/nelly app add "$NAME" --name e --local /tmp --schedule "*/5 * * * *" --entrypoint e.py >/dev/null
explain_out="$(bin/nelly explain "$NAME")"
if [[ "$explain_out" == *"Apps"* ]] && [[ "$explain_out" == *"local: /tmp"* ]]; then
    pass "explain prints apps section"
else
    fail "explain apps section missing"
fi

# ----------------------------------------------------------------------------
section "doctor (offline-friendly: should not fail just because docker is absent here)"
# Doctor returns non-zero when problems are found. We expect at least one problem
# in this sandbox (no docker daemon), so we check that it ran and produced output.
out="$(bin/nelly doctor "$NAME" 2>&1 || true)"
echo "$out" | grep -q "Checking deployment" \
    && pass "doctor reports its findings" || fail "doctor didn't run"

# ----------------------------------------------------------------------------
section "list / json output"
if bin/nelly list --json | jq -e ".[] | select(.deployment == \"$NAME\")" >/dev/null; then
    pass "list --json includes $NAME"
else
    fail "list --json missing $NAME"
fi

# ----------------------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf '\033[32mall smoke checks passed\033[0m\n'
    exit 0
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$FAIL"
    exit 1
fi
