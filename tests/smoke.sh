#!/usr/bin/env bash
# tests/smoke.sh — fast offline checks. Runs without Docker.
#
# What it covers:
#   - All shell scripts pass `bash -n` (syntax).
#   - `bash -n` over every script (and shellcheck if installed).
#   - The CLI prints help.
#   - A fresh `nelly init` creates a deployment whose config validates.
#   - add-app / remove-app / set-schedule / set / get round-trip.
#   - secrets set/list/unset round-trip; .env mode is 0600.
#   - Invalid configs are rejected.
#
# Run from repo root:   bash tests/smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
cd "$ROOT"

FAIL=0
pass() { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
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
section "cli help"
if bin/nelly --help >/dev/null 2>&1; then pass "nelly --help"; else fail "nelly --help"; fi
if bin/nelly help deploy >/dev/null 2>&1; then pass "nelly help deploy"; else fail "nelly help deploy"; fi

# ----------------------------------------------------------------------------
section "init → validate"
NAME="smoketest-$$"
DIR="containers/$NAME"
trap 'rm -rf "$DIR"' EXIT

bin/nelly init "$NAME" >/dev/null
[[ -f "$DIR/def/config.json" ]] && pass "init created config.json" || fail "init missing config.json"
bin/nelly validate "$NAME" >/dev/null 2>&1 && pass "default config validates" || fail "default config invalid"

# container/image names should match the deployment name after init
cn="$(bin/nelly get "$NAME" '.container_name')"
[[ "$cn" == "$NAME" ]] && pass "init sets container_name=$NAME" || fail "container_name=$cn"

# ----------------------------------------------------------------------------
section "add-app / remove-app / set-schedule"
bin/nelly add-app "$NAME" --name foo --local /tmp --schedule "*/5 * * * *" --entrypoint main.py >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="foo")] | length')" == "1" ]] \
    && pass "added app 'foo'" || fail "add-app failed"

bin/nelly set-schedule "$NAME" foo "0 9 * * *" >/dev/null
sched="$(bin/nelly get "$NAME" '.apps[] | select(.app_name=="foo") | .schedule')"
[[ "$sched" == "0 9 * * *" ]] && pass "set-schedule" || fail "set-schedule got $sched"

bin/nelly remove-app "$NAME" foo >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="foo")] | length')" == "0" ]] \
    && pass "removed app 'foo'" || fail "remove-app failed"

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
# bad cron
if bin/nelly add-app "$NAME" --name bad --local /tmp --schedule "not a cron" --entrypoint m.py >/dev/null 2>&1; then
    fail "accepted bad cron expression"
else
    pass "rejected bad cron"
fi
# bad image name
if bin/nelly set "$NAME" '.image_name' 'BAD NAME' >/dev/null 2>&1; then
    fail "accepted bad image name"
else
    pass "rejected bad image name"
fi

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
