#!/usr/bin/env bash
# tests/smoke.sh — offline checks. Runs without Docker.
#
# Coverage:
#   - syntax (bash -n) + optional shellcheck
#   - --version and help text
#   - init -y → validate
#   - app add/list/show/remove/schedule/ref/path
#   - set / get / atomic rejection
#   - secrets set/list/unset; .env mode 0600
#   - invalid configs are rejected and rolled back
#   - explain + doctor
#   - tag add/remove/list
#   - export → import round-trip (with and without secrets)
#   - clone
#   - backup → restore round-trip
#   - cron preview
#   - all list
#   - plan
#   - list --json

set -euo pipefail
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
cd "$ROOT"

FAIL=0
pass()    { printf '  \033[32mok\033[0m  %s\n' "$*"; }
fail()    { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
section() { printf '\n== %s ==\n' "$*"; }

cleanup() {
    rm -rf containers/smoketest-* /tmp/nelly-smoke-*.json /tmp/nelly-smoke-*.tar.gz 2>/dev/null || true
}
trap cleanup EXIT

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
section "version + help"
bin/nelly --version | grep -q '^nelly ' && pass "--version" || fail "--version"
bin/nelly 2>&1 | grep -q "First time?" && pass "intro renders"      || fail "intro missing"
bin/nelly help >/dev/null 2>&1         && pass "help renders"       || fail "help"
bin/nelly help deploy >/dev/null 2>&1  && pass "help deploy"        || fail "help deploy"
bin/nelly help export >/dev/null 2>&1  && pass "help export"        || fail "help export"
bin/nelly help all >/dev/null 2>&1     && pass "help all"           || fail "help all"

# ----------------------------------------------------------------------------
section "init (non-interactive) → validate"
NAME="smoketest-$$"
DIR="containers/$NAME"

bin/nelly -y init "$NAME" >/dev/null 2>&1
[[ -f "$DIR/def/config.json" ]] && pass "init created config.json" || fail "init missing config.json"
bin/nelly validate "$NAME" >/dev/null 2>&1 && pass "default config validates" || fail "default config invalid"

cn="$(bin/nelly get "$NAME" '.container_name')"
[[ "$cn" == "$NAME" ]] && pass "init sets container_name=$NAME" || fail "container_name=$cn"
[[ "$(bin/nelly get "$NAME" '.apps | length')" == "0" ]] && pass "init starts with zero apps" || fail "init left apps in config"

# ----------------------------------------------------------------------------
section "app subcommand"
bin/nelly app add "$NAME" \
    --name foo --local /tmp \
    --schedule "*/5 * * * *" --entrypoint main.py >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="foo")] | length')" == "1" ]] \
    && pass "app add (flag-driven)" || fail "app add failed"

bin/nelly app list "$NAME" | grep -q "^foo" \
    && pass "app list shows foo" || fail "app list output"

bin/nelly app show "$NAME" foo | jq -e '.entrypoint == "main.py"' >/dev/null \
    && pass "app show returns json" || fail "app show output"

bin/nelly app schedule "$NAME" foo "0 9 * * *" >/dev/null
[[ "$(bin/nelly get "$NAME" '.apps[] | select(.app_name=="foo") | .schedule')" == "0 9 * * *" ]] \
    && pass "app schedule" || fail "schedule mismatch"

bin/nelly app path "$NAME" foo "/var/tmp" >/dev/null
[[ "$(bin/nelly get "$NAME" '.apps[] | select(.app_name=="foo") | .source.path')" == "/var/tmp" ]] \
    && pass "app path" || fail "path mismatch"

bin/nelly app remove "$NAME" foo >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="foo")] | length')" == "0" ]] \
    && pass "app remove" || fail "app remove"

# legacy aliases
bin/nelly add-app "$NAME" --name legacy --local /tmp --schedule "@daily" --entrypoint x.py >/dev/null
[[ "$(bin/nelly get "$NAME" '[.apps[] | select(.app_name=="legacy")] | length')" == "1" ]] \
    && pass "legacy 'add-app' alias works" || fail "alias add-app"
bin/nelly remove-app "$NAME" legacy >/dev/null

# ----------------------------------------------------------------------------
section "set / get + atomic rejection"
bin/nelly set "$NAME" '.resources.cpus' '2.0' >/dev/null
[[ "$(bin/nelly get "$NAME" '.resources.cpus')" == "2.0" ]] && pass "set/get .resources.cpus" || fail "cpus"

bin/nelly set "$NAME" '.resources.pids_limit' '512' >/dev/null
[[ "$(bin/nelly get "$NAME" '.resources.pids_limit')" == "512" ]] && pass "JSON-typed number" || fail "pids"

if bin/nelly set "$NAME" '.image_name' 'BAD NAME' >/dev/null 2>&1; then
    fail "accepted bad image name"
else
    pass "rejected bad image name"
fi
# .image_name should still be the previous valid value
[[ "$(bin/nelly get "$NAME" '.image_name')" == "$NAME" ]] \
    && pass "rejected change rolled back atomically" || fail "rollback broken: $(bin/nelly get "$NAME" '.image_name')"

# ----------------------------------------------------------------------------
section "secrets"
bin/nelly secrets set "$NAME" FOO=bar 'BAZ=quoted "value"' >/dev/null
mode="$(stat -c %a "$DIR/def/.env")"
[[ "$mode" == "600" ]] && pass ".env mode 0600" || fail ".env mode is $mode"
keys="$(bin/nelly secrets list "$NAME" | sort | tr '\n' ' ')"
[[ "$keys" == "BAZ FOO " ]] && pass "secrets list keys only" || fail "got: $keys"
bin/nelly secrets unset "$NAME" FOO >/dev/null
remaining="$(bin/nelly secrets list "$NAME")"
[[ "$remaining" == "BAZ" ]] && pass "secrets unset" || fail "got: $remaining"

# ----------------------------------------------------------------------------
section "tags"
bin/nelly tag "$NAME" add prod critical >/dev/null
[[ "$(bin/nelly tag "$NAME" list | sort | tr '\n' ' ')" == "critical prod " ]] \
    && pass "tag add + list" || fail "tag list: $(bin/nelly tag "$NAME" list)"
bin/nelly tag "$NAME" remove critical >/dev/null
[[ "$(bin/nelly tag "$NAME" list | tr '\n' ' ')" == "prod " ]] && pass "tag remove" || fail "tag remove"

# ----------------------------------------------------------------------------
section "explain / cron / plan"
bin/nelly app add "$NAME" --name e --local /tmp --schedule "*/5 * * * *" --entrypoint e.py >/dev/null
explain_out="$(bin/nelly explain "$NAME")"
[[ "$explain_out" == *"Apps"* && "$explain_out" == *"local: /tmp"* ]] \
    && pass "explain prints apps section" || fail "explain output incomplete"

cron_out="$(bin/nelly cron "$NAME")"
[[ "$cron_out" == *"every 5 minute"* ]] \
    && pass "cron describes schedule" || fail "cron output: $cron_out"

plan_out="$(bin/nelly plan "$NAME" 2>&1)"
[[ "$plan_out" == *"Plan for: $NAME"* ]] \
    && pass "plan renders" || fail "plan output"

# ----------------------------------------------------------------------------
section "export → import round-trip"
EXPORT_FILE="/tmp/nelly-smoke-$$.json"
bin/nelly export "$NAME" > "$EXPORT_FILE"
jq -e '.nelly_export_version == 1' "$EXPORT_FILE" >/dev/null \
    && pass "export has version" || fail "export version"
jq -e '.secrets_included == false' "$EXPORT_FILE" >/dev/null \
    && pass "secrets excluded by default" || fail "secrets leaked"

NEW="smoketest-imp-$$"
bin/nelly import "$EXPORT_FILE" --as "$NEW" >/dev/null 2>&1
[[ -d "containers/$NEW" ]] && pass "import created deployment" || fail "import"
[[ "$(bin/nelly get "$NEW" '.container_name')" == "$NEW" ]] \
    && pass "import retargets container_name" || fail "import name"

# with --include-secrets
bin/nelly export "$NAME" --include-secrets > "$EXPORT_FILE.with-secrets" 2>/dev/null
jq -e '.secrets_included == true' "$EXPORT_FILE.with-secrets" >/dev/null \
    && pass "--include-secrets sets flag" || fail "secrets flag"

# ----------------------------------------------------------------------------
section "clone"
CLONE="smoketest-clone-$$"
bin/nelly clone "$NAME" "$CLONE" >/dev/null 2>&1
[[ -d "containers/$CLONE" ]] && pass "clone created deployment" || fail "clone"
[[ "$(bin/nelly get "$CLONE" '.apps | length')" == "$(bin/nelly get "$NAME" '.apps | length')" ]] \
    && pass "clone has same apps" || fail "clone apps mismatch"

# ----------------------------------------------------------------------------
section "backup → restore round-trip"
TARBALL="/tmp/nelly-smoke-$$.tar.gz"
bin/nelly backup "$NAME" --out "$TARBALL" >/dev/null 2>&1
[[ -f "$TARBALL" ]] && pass "backup produced tarball" || fail "backup"

REST="smoketest-rest-$$"
bin/nelly restore "$TARBALL" --as "$REST" >/dev/null 2>&1
[[ -d "containers/$REST" ]] && pass "restore created deployment" || fail "restore"
[[ "$(bin/nelly get "$REST" '.container_name')" == "$REST" ]] \
    && pass "restore retargets name" || fail "restore name"

# ----------------------------------------------------------------------------
section "all (multi-deployment)"
bin/nelly all list >/dev/null 2>&1 && pass "all list runs" || fail "all list"
all_out="$(bin/nelly all list --tag prod)"
[[ "$all_out" == *"$NAME"* ]] && pass "all list --tag filters" || fail "all list --tag: $all_out"

# ----------------------------------------------------------------------------
section "invalid configs rejected"
if bin/nelly app add "$NAME" --name bad --local /tmp --schedule "not a cron" --entrypoint m.py >/dev/null 2>&1; then
    fail "accepted bad cron"
else
    pass "rejected bad cron"
fi
if bin/nelly tag "$NAME" add 'bad tag!' >/dev/null 2>&1; then
    fail "accepted bad tag"
else
    pass "rejected bad tag"
fi

# ----------------------------------------------------------------------------
section "security: dangerous inputs are rejected"

# Entrypoint must not contain shell metacharacters (was: cron injection → RCE).
if bin/nelly app add "$NAME" --name shellinject --local /tmp \
       --schedule "*/5 * * * *" --entrypoint "x.py; rm -rf /" >/dev/null 2>&1; then
    fail "accepted entrypoint with shell metachars"
else
    pass "rejected entrypoint with shell metachars"
fi
if bin/nelly app add "$NAME" --name dotdot --local /tmp \
       --schedule "*/5 * * * *" --entrypoint "../../etc/passwd" >/dev/null 2>&1; then
    fail "accepted entrypoint with '..'"
else
    pass "rejected entrypoint with '..'"
fi

# Local source path must not be a system dir (without an explicit opt-in).
if bin/nelly app add "$NAME" --name etcsrc --local /etc \
       --schedule "*/5 * * * *" --entrypoint x.py >/dev/null 2>&1; then
    fail "accepted local source = /etc"
else
    pass "rejected local source pointing at /etc"
fi

# Git argument injection: refs/URLs starting with '-' are refused.
if bin/nelly app add "$NAME" --name dashref \
       --git "git@example.com:me/x.git" --ref "-evil" \
       --schedule "*/5 * * * *" --entrypoint x.py >/dev/null 2>&1; then
    fail "accepted ref starting with '-'"
else
    pass "rejected ref starting with '-'"
fi
if bin/nelly app add "$NAME" --name dashurl \
       --git "--upload-pack=/tmp/evil" \
       --schedule "*/5 * * * *" --entrypoint x.py >/dev/null 2>&1; then
    fail "accepted git URL starting with '-'"
else
    pass "rejected git URL starting with '-'"
fi

# Volumes: must not be a deny-listed host path without opt-in.
if bin/nelly set "$NAME" '.volumes' '["/:/host"]' >/dev/null 2>&1; then
    fail "accepted root bind mount"
else
    pass "rejected root bind mount"
fi
if bin/nelly set "$NAME" '.volumes' '["/etc:/x"]' >/dev/null 2>&1; then
    fail "accepted /etc bind mount"
else
    pass "rejected /etc bind mount"
fi
if bin/nelly set "$NAME" '.volumes' '["/var/run/docker.sock:/var/run/docker.sock"]' >/dev/null 2>&1; then
    fail "accepted docker.sock bind mount"
else
    pass "rejected docker.sock bind mount"
fi
# Allow-listed paths still work
if bin/nelly set "$NAME" '.volumes' '["/srv/data:/data:ro"]' >/dev/null 2>&1; then
    pass "accepted safe volume"
else
    fail "rejected safe volume"
fi
bin/nelly set "$NAME" '.volumes' '[]' >/dev/null 2>&1

# Hooks: absolute paths and '..' both refused.
if bin/nelly set "$NAME" '.hooks.pre_deploy' '/usr/bin/curl' >/dev/null 2>&1; then
    fail "accepted absolute hook path"
else
    pass "rejected absolute hook path"
fi
if bin/nelly set "$NAME" '.hooks.pre_deploy' '../../etc/shadow' >/dev/null 2>&1; then
    fail "accepted hook path with '..'"
else
    pass "rejected hook path with '..'"
fi
bin/nelly set "$NAME" '.hooks.pre_deploy' '' >/dev/null 2>&1

# ----------------------------------------------------------------------------
section "doctor (offline-friendly)"
bin/nelly doctor "$NAME" >/dev/null 2>&1 || true
# we just want it to have run; non-zero is expected here (no docker daemon in test env)
pass "doctor ran"

# ----------------------------------------------------------------------------
section "list --json"
bin/nelly list --json | jq -e ".[] | select(.deployment == \"$NAME\")" >/dev/null \
    && pass "list --json includes $NAME" || fail "list --json"

# ----------------------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf '\033[32mall smoke checks passed\033[0m\n'
    exit 0
else
    printf '\033[31m%d check(s) failed\033[0m\n' "$FAIL"
    exit 1
fi
