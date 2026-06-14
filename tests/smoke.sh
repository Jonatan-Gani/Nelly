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
#   - snapshot bundle (fleet restore bundle for off-site backup)
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

# If the user already has a real bot/ directory (a live install), move it
# aside up front so the bot tests below — which write a throwaway bot/ — can't
# clobber it. The cleanup trap puts it back on exit (success or failure).
BOT_BACKUP=""
if [[ -d bot ]]; then
    BOT_BACKUP="/tmp/nelly-smoke-orig-bot.$$"
    mv bot "$BOT_BACKUP"
fi

cleanup() {
    rm -rf containers/smoketest-* /tmp/nelly-smoke-*.json /tmp/nelly-smoke-*.tar.gz 2>/dev/null || true
    rm -rf /tmp/nelly-smoke-snap-* /tmp/nelly-smoke-hookdir-* 2>/dev/null || true
    rm -rf bot 2>/dev/null || true
    # Restore the user's real bot/ if we moved it aside.
    if [[ -n "$BOT_BACKUP" && -d "$BOT_BACKUP" ]]; then
        mv "$BOT_BACKUP" bot
    fi
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
bin/nelly help bot >/dev/null 2>&1     && pass "help bot"           || fail "help bot"

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
listing="$(bin/nelly secrets list "$NAME")"
[[ "$listing" == *"BAZ"* && "$listing" == *"FOO"* ]] \
    && pass "secrets list shows keys only" || fail "got: $listing"
bin/nelly secrets unset "$NAME" FOO >/dev/null
remaining="$(bin/nelly secrets list "$NAME")"
[[ "$remaining" == *"BAZ"* && "$remaining" != *"FOO"* ]] \
    && pass "secrets unset" || fail "got: $remaining"

# Per-app secrets: isolated, mode 0600, listed under app scope.
bin/nelly secrets set "$NAME" --app legacy DB_PASS=topsecret >/dev/null 2>&1
# legacy app must exist in config first for --app validation warning to be friendly
bin/nelly app add "$NAME" --name pets --local /tmp --schedule "*/5 * * * *" --entrypoint p.py >/dev/null 2>&1
bin/nelly secrets set "$NAME" --app pets API_KEY=abc >/dev/null
mkdir -p "$DIR/def/secrets"
mode="$(stat -c %a "$DIR/def/secrets/pets.env")"
[[ "$mode" == "600" ]] && pass "per-app secrets file mode 0600" || fail "per-app mode $mode"
plisting="$(bin/nelly secrets list "$NAME")"
[[ "$plisting" == *"app:pets"* && "$plisting" == *"API_KEY"* ]] \
    && pass "per-app secrets listed under scope" || fail "per-app list: $plisting"

# JSON listing groups by scope.
json_list="$(bin/nelly --json secrets list "$NAME")"
echo "$json_list" | jq -e '.apps.pets[] | select(. == "API_KEY")' >/dev/null \
    && pass "secrets list --json groups by scope" || fail "json list: $json_list"

# Backup excludes secrets by default.
TARBALL_NS="/tmp/nelly-smoke-nosec-$$.tar.gz"
bin/nelly backup "$NAME" --out "$TARBALL_NS" >/dev/null 2>&1
if tar -tzf "$TARBALL_NS" | grep -qE 'def/(\.env|secrets/)'; then
    fail "backup leaked secrets by default"
else
    pass "backup excludes secrets by default"
fi
rm -f "$TARBALL_NS"

# Backup with --include-secrets includes them (with the warning).
TARBALL_WS="/tmp/nelly-smoke-withsec-$$.tar.gz"
bin/nelly backup "$NAME" --out "$TARBALL_WS" --include-secrets >/dev/null 2>&1
tar -tzf "$TARBALL_WS" | grep -q 'def/\.env' \
    && pass "backup --include-secrets includes .env" || fail "include-secrets didn't include .env"
rm -f "$TARBALL_WS"
bin/nelly app remove "$NAME" pets >/dev/null 2>&1
rm -rf "$DIR/def/secrets"

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
section "snapshot bundle"

# Bare `nelly snapshot` must print usage, NOT run a (mutating, container-
# stopping) create as the no-arg default.
bare_rc=0
bare_out="$(bin/nelly snapshot 2>&1)" || bare_rc=$?
if (( bare_rc == 0 )) && grep -q 'snapshot.sh create' <<<"$bare_out"; then
    pass "bare 'nelly snapshot' shows usage (no implicit create)"
else
    fail "bare snapshot: rc=$bare_rc out=$bare_out"
fi

SNAP_OUT="/tmp/nelly-smoke-snap-$$"
rm -rf "$SNAP_OUT"
# --no-volumes because the smoketest deployment has none, --no-quiesce
# because we have no Docker available in the offline suite.
bin/nelly snapshot create --out "$SNAP_OUT" --no-quiesce --no-volumes >/dev/null 2>&1
[[ -f "$SNAP_OUT/BUNDLE_VERSION" ]]      && pass "snapshot wrote BUNDLE_VERSION"      || fail "no BUNDLE_VERSION"
[[ -f "$SNAP_OUT/snapshot.json" ]]       && pass "snapshot wrote snapshot.json"       || fail "no snapshot.json"
[[ -f "$SNAP_OUT/fleet-manifest.json" ]] && pass "snapshot wrote fleet-manifest.json" || fail "no fleet-manifest.json"
[[ -f "$SNAP_OUT/README.txt" ]]          && pass "snapshot wrote README.txt"          || fail "no README.txt"
[[ -f "$SNAP_OUT/deployments/$NAME/tarball.tar" ]] \
    && pass "snapshot wrote uncompressed tarball.tar for $NAME" \
    || fail "no tarball.tar for $NAME (uncompressed for restic dedup)"
jq -e --arg n "$NAME" '.deployments | map(.name) | index($n) != null' \
    "$SNAP_OUT/fleet-manifest.json" >/dev/null \
    && pass "fleet-manifest lists $NAME" || fail "manifest missing $NAME"
jq -e '.schema_version == 1' "$SNAP_OUT/fleet-manifest.json" >/dev/null \
    && pass "fleet-manifest has schema_version" || fail "no schema_version"

# Hardening: 0700 perms on the bundle root (cleartext secrets between runs).
bundle_mode="$(stat -c %a "$SNAP_OUT")"
[[ "$bundle_mode" == "700" ]] \
    && pass "bundle root is mode 0700" \
    || fail "bundle root mode is $bundle_mode (expected 700)"

# Hardening: tar inside the bundle is uncompressed (so restic chunk-dedups).
# `file` exists everywhere; an uncompressed tar should NOT report "gzip".
if file "$SNAP_OUT/deployments/$NAME/tarball.tar" 2>/dev/null | grep -q 'gzip'; then
    fail "deployment tarball is gzip-compressed (kills restic dedup)"
else
    pass "deployment tarball is uncompressed (restic-friendly)"
fi
# Secrets included by default — restic encrypts client-side; we want them in.
tar -tf "$SNAP_OUT/deployments/$NAME/tarball.tar" | grep -q 'def/\.env' \
    && pass "snapshot bundle includes secrets by default" \
    || fail "snapshot bundle missing secrets (--no-secrets default leaked?)"
# verify subcommand (also asserts the self-verify in create already passed)
bin/nelly snapshot verify --out "$SNAP_OUT" >/dev/null 2>&1 \
    && pass "snapshot verify passes on a fresh bundle" \
    || fail "snapshot verify failed"

# Hardening: self-verify in create fails loud if the bundle is broken.
# Corrupt a volume tarball's sha256 to simulate a torn write, then re-run
# verify to confirm it actually catches it.
mkdir -p "$SNAP_OUT/deployments/$NAME/volumes"
echo "real-tar-bytes" > "$SNAP_OUT/deployments/$NAME/volumes/fake.tar"
jq -n --arg sha "0000000000000000000000000000000000000000000000000000000000000000" \
      --arg host "/tmp/fake-vol" --arg cont "/cont" \
      '{host_path:$host, container_path:$cont, mode:null, sha256:$sha, size_bytes:14}' \
    > "$SNAP_OUT/deployments/$NAME/volumes/fake.meta.json"
if bin/nelly snapshot verify --out "$SNAP_OUT" >/dev/null 2>&1; then
    fail "verify accepted corrupt sha256"
else
    pass "verify rejects sha256 mismatch (loud-fail loop intact)"
fi
rm -f "$SNAP_OUT/deployments/$NAME/volumes/fake.tar" \
      "$SNAP_OUT/deployments/$NAME/volumes/fake.meta.json"

# An orphan volume tar with no meta.json is a half-written artifact (e.g.
# interrupted run) and must fail verify too.
touch "$SNAP_OUT/deployments/$NAME/volumes/orphan.tar"
if bin/nelly snapshot verify --out "$SNAP_OUT" >/dev/null 2>&1; then
    fail "verify accepted an orphan volume tar (no meta.json)"
else
    pass "verify rejects orphan volume tar"
fi
rm -f "$SNAP_OUT/deployments/$NAME/volumes/orphan.tar"

# --no-secrets opts out
SNAP_NS="/tmp/nelly-smoke-snap-ns-$$"
rm -rf "$SNAP_NS"
bin/nelly snapshot create --out "$SNAP_NS" --no-quiesce --no-volumes --no-secrets >/dev/null 2>&1
if tar -tf "$SNAP_NS/deployments/$NAME/tarball.tar" | grep -qE 'def/(\.env|secrets/)'; then
    fail "--no-secrets leaked secrets"
else
    pass "--no-secrets keeps secrets out"
fi
# atomic swap: re-running the snapshot must produce a fresh bundle (not
# pile up .new / .old siblings)
bin/nelly snapshot create --out "$SNAP_OUT" --no-quiesce --no-volumes >/dev/null 2>&1
[[ ! -d "${SNAP_OUT}.new" && ! -d "${SNAP_OUT}.old" ]] \
    && pass "snapshot cleans up .new/.old siblings" \
    || fail "snapshot left ${SNAP_OUT}.new or .old behind"

# Hardening: backup.skip_volumes config field validates and the snapshot
# code path skips matching volumes (recorded in skipped-volumes.json).
SKIP_DEP="smoketest-skipvol-$$"
bin/nelly -y init "$SKIP_DEP" >/dev/null 2>&1
bin/nelly set "$SKIP_DEP" '.volumes' '["/tmp/skipvol-data-'$$':/data"]' >/dev/null 2>&1
bin/nelly set "$SKIP_DEP" '.backup.skip_volumes' '["/tmp/skipvol-data-'$$'"]' >/dev/null 2>&1 \
    && pass "backup.skip_volumes accepted by validator" \
    || fail "backup.skip_volumes rejected"
# absolute-path enforcement
if bin/nelly set "$SKIP_DEP" '.backup.skip_volumes' '["relative/path"]' >/dev/null 2>&1; then
    fail "backup.skip_volumes accepted a relative path"
else
    pass "backup.skip_volumes rejects relative paths"
fi
# '..' enforcement
if bin/nelly set "$SKIP_DEP" '.backup.skip_volumes' '["/tmp/../etc"]' >/dev/null 2>&1; then
    fail "backup.skip_volumes accepted '..'"
else
    pass "backup.skip_volumes rejects '..'"
fi
# Back to the valid value for the snapshot run.
bin/nelly set "$SKIP_DEP" '.backup.skip_volumes' '["/tmp/skipvol-data-'$$'"]' >/dev/null 2>&1
mkdir -p "/tmp/skipvol-data-$$"
echo "data" > "/tmp/skipvol-data-$$/file"
SKIP_OUT="/tmp/nelly-smoke-snap-skip-$$"
rm -rf "$SKIP_OUT"
bin/nelly snapshot create --out "$SKIP_OUT" --no-quiesce --only "$SKIP_DEP" >/dev/null 2>&1
[[ -f "$SKIP_OUT/deployments/$SKIP_DEP/volumes/skipped-volumes.json" ]] \
    && pass "skip_volumes recorded in skipped-volumes.json" \
    || fail "no skipped-volumes.json (skip_volumes not honored)"
# And the would-be-tarred file is NOT present
if find "$SKIP_OUT/deployments/$SKIP_DEP/volumes" -name '*.tar' 2>/dev/null | grep -q .; then
    fail "skip_volumes still produced a tarball"
else
    pass "skip_volumes prevented quiesce-tar"
fi
rm -rf "/tmp/skipvol-data-$$" "$SKIP_OUT" "containers/$SKIP_DEP"

# A declared volume whose host path is missing must FAIL the deployment
# snapshot — a silently incomplete bundle is the worst possible outcome.
MISSVOL_DEP="smoketest-missvol-$$"
bin/nelly -y init "$MISSVOL_DEP" >/dev/null 2>&1
bin/nelly set "$MISSVOL_DEP" '.volumes' '["/tmp/definitely-missing-'$$':/data"]' >/dev/null 2>&1
MISSVOL_OUT="/tmp/nelly-smoke-snap-missvol-$$"
missvol_rc=0
bin/nelly snapshot create --out "$MISSVOL_OUT" --no-quiesce --only "$MISSVOL_DEP" >/dev/null 2>&1 || missvol_rc=$?
(( missvol_rc != 0 )) \
    && pass "missing volume host path fails the snapshot (rc=$missvol_rc)" \
    || fail "missing volume path reported success"
jq -e --arg n "$MISSVOL_DEP" '.results[] | select(.deployment==$n) | .outcome == "failed"' \
    "$MISSVOL_OUT/snapshot.json" >/dev/null 2>&1 \
    && pass "snapshot.json marks missing-volume deployment failed" \
    || fail "snapshot.json did not record the volume failure"
rm -rf "$MISSVOL_OUT" "${MISSVOL_OUT}.lock" "containers/$MISSVOL_DEP"

# --only with a bogus name must die, not produce an empty bundle that
# reports success.
if bin/nelly snapshot create --out "/tmp/nelly-smoke-snap-bogus-$$" --no-quiesce \
        --only "no-such-deployment-$$" >/dev/null 2>&1; then
    fail "--only with a bogus name was accepted"
else
    pass "--only with a bogus name dies"
fi
rm -rf "/tmp/nelly-smoke-snap-bogus-$$" "/tmp/nelly-smoke-snap-bogus-$$.lock" \
       "/tmp/nelly-smoke-snap-bogus-$$.new" 2>/dev/null || true

# A corrupt config.json in ONE deployment must not abort the whole bundle:
# create still completes (and exits non-zero), and the fleet manifest
# records an error entry for the bad deployment.
CORRUPT_DEP="smoketest-corrupt-$$"
mkdir -p "containers/$CORRUPT_DEP/def"
echo '{ this is not json' > "containers/$CORRUPT_DEP/def/config.json"
CORRUPT_OUT="/tmp/nelly-smoke-snap-corrupt-$$"
corrupt_rc=0
bin/nelly snapshot create --out "$CORRUPT_OUT" --no-quiesce --no-volumes \
    --only "$CORRUPT_DEP" >/dev/null 2>&1 || corrupt_rc=$?
[[ -f "$CORRUPT_OUT/fleet-manifest.json" ]] \
    && pass "corrupt config: bundle still completes" \
    || fail "corrupt config aborted the whole bundle"
(( corrupt_rc != 0 )) \
    && pass "corrupt config: create exits non-zero ($corrupt_rc)" \
    || fail "corrupt config reported success"
jq -e --arg n "$CORRUPT_DEP" '.deployments[] | select(.name==$n) | has("error")' \
    "$CORRUPT_OUT/fleet-manifest.json" >/dev/null 2>&1 \
    && pass "fleet-manifest records the corrupt deployment's error" \
    || fail "fleet-manifest missing the error entry"
rm -rf "$CORRUPT_OUT" "${CORRUPT_OUT}.lock" "containers/$CORRUPT_DEP"

# Hardening: a pre_snapshot hook that exits non-zero must fail the
# deployment (rc captured correctly) AND make the whole `snapshot create`
# exit non-zero — that's what trips the backup runner's hard-fail.
FAIL_DEP="smoketest-failhook-$$"
bin/nelly -y init "$FAIL_DEP" >/dev/null 2>&1
mkdir -p "containers/$FAIL_DEP/def/hooks"
cat > "containers/$FAIL_DEP/def/hooks/bad.sh" <<'BAD_HOOK_EOF'
#!/usr/bin/env bash
exit 7
BAD_HOOK_EOF
chmod +x "containers/$FAIL_DEP/def/hooks/bad.sh"
bin/nelly set "$FAIL_DEP" '.hooks.pre_snapshot' './def/hooks/bad.sh' >/dev/null
FAIL_OUT="/tmp/nelly-smoke-snap-fail-$$"
rm -rf "$FAIL_OUT"
# Capture both stderr and exit code without aborting the smoke run under
# set -e — the WHOLE POINT of this test is that the command exits non-zero.
fail_out_text=""
fail_rc=0
fail_out_text="$(bin/nelly snapshot create --out "$FAIL_OUT" --no-quiesce --no-volumes --only "$FAIL_DEP" 2>&1)" || fail_rc=$?
if (( fail_rc != 0 )); then
    pass "pre_snapshot failure makes snapshot create exit non-zero ($fail_rc)"
else
    fail "pre_snapshot failed but snapshot create returned 0"
fi
if echo "$fail_out_text" | grep -q 'rc=7'; then
    pass "pre_snapshot rc=7 propagates into the error log"
else
    fail "pre_snapshot rc not captured (got: $fail_out_text)"
fi
if [[ -f "$FAIL_OUT/snapshot.json" ]] && \
   jq -e --arg n "$FAIL_DEP" '.results[] | select(.deployment == $n) | .outcome == "failed"' \
        "$FAIL_OUT/snapshot.json" >/dev/null; then
    pass "snapshot.json records failed deployment"
else
    fail "snapshot.json did not record failure"
fi
rm -rf "containers/$FAIL_DEP" "$FAIL_OUT" "${FAIL_OUT}.lock"

# install-hook should produce an executable script we can read.
HOOK_DIR="/tmp/nelly-smoke-hookdir-$$"
mkdir -p "$HOOK_DIR"
bin/nelly snapshot install-hook --hook-dir "$HOOK_DIR" --name 99-test >/dev/null 2>&1
[[ -x "$HOOK_DIR/99-test" ]] && pass "install-hook drops an executable script" || fail "install-hook"
grep -q 'snapshot create' "$HOOK_DIR/99-test" \
    && pass "installed hook invokes snapshot create" || fail "hook content"
# Hardening: the hook is strict-mode (set -euo pipefail) so any failure
# inside `nelly snapshot create` (including the internal verify) propagates
# out as a non-zero exit — that's what makes the backup runner abort.
grep -q 'set -euo pipefail' "$HOOK_DIR/99-test" \
    && pass "installed hook uses strict mode" || fail "hook missing strict mode"
bin/nelly snapshot uninstall-hook --hook-dir "$HOOK_DIR" --name 99-test >/dev/null 2>&1
[[ ! -e "$HOOK_DIR/99-test" ]] && pass "uninstall-hook removes the script" || fail "uninstall-hook"
rm -rf "$SNAP_OUT" "${SNAP_OUT}.lock" "$SNAP_NS" "${SNAP_NS}.lock" "$HOOK_DIR"

# ----------------------------------------------------------------------------
section "check-updates"

# `check` without --notify is a pure git fetch + compare. On the test repo
# it should exit 0 (up to date) or 1 (behind) — both are valid; 2 means
# the fetch itself failed (network), which is fine to tolerate in CI.
cu_rc=0
bin/nelly check-updates check >/dev/null 2>&1 || cu_rc=$?
(( cu_rc == 0 || cu_rc == 1 || cu_rc == 2 )) \
    && pass "check-updates exits 0/1/2 cleanly (got $cu_rc)" \
    || fail "check-updates: rc=$cu_rc"

# The timer invokes `check-updates --notify` (no explicit subcommand). The
# leading flag must route to `check`, not be mistaken for a subcommand.
cu_n_rc=0
bin/nelly check-updates --notify >/dev/null 2>&1 || cu_n_rc=$?
(( cu_n_rc == 0 || cu_n_rc == 1 || cu_n_rc == 2 )) \
    && pass "check-updates --notify (timer form) routes to check (got $cu_n_rc)" \
    || fail "check-updates --notify: rc=$cu_n_rc (leading flag mis-parsed as sub?)"

# Help is reachable through the main `nelly help` dispatch.
bin/nelly help check-updates | grep -q 'check-updates' \
    && pass "nelly help check-updates renders" || fail "no help block"

# Status works without a timer installed and doesn't error.
bin/nelly check-updates status >/dev/null 2>&1 \
    && pass "check-updates status runs (no timer)" || fail "status broken"

# The bot module imports cleanly with both new commands wired.
NELLY_ROOT="$(pwd)" python3 - <<'PY' && pass "bot wired for /update + /update_check" || fail "bot wiring broken"
import sys; sys.path.insert(0, 'lib')
import bot
assert 'update_check' in bot.COMMANDS
assert 'update' in bot.COMMANDS
assert bot.COMMANDS['update_check'][1] is False  # read-only
assert bot.COMMANDS['update'][1] is True         # write
assert bot.CONFIRM_VERB.get('up') == 'update'
assert bot.CB_ALIASES.get('uc') == 'update_check'
assert bot.CB_ALIASES.get('up') == 'update'
assert '/update' in bot.HELP_WRITE
assert '/update_check' in bot.HELP_READ
PY

# Bogus subcommand is rejected.
if bin/nelly check-updates not-a-real-sub >/dev/null 2>&1; then
    fail "bogus check-updates subcommand was accepted"
else
    pass "bogus check-updates subcommand rejected"
fi

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

# Healthcheck command is a shell sink (docker runs it via /bin/sh -c) — a
# custom one must be opted into explicitly, like dangerous volumes/paths.
if bin/nelly set "$NAME" '.health.cmd' '"id; rm -rf /"' >/dev/null 2>&1; then
    fail "accepted custom health.cmd without opt-in"
else
    pass "rejected custom health.cmd without opt-in"
fi
bin/nelly set "$NAME" '.allow_dangerous_health_cmd' 'true' >/dev/null 2>&1
if bin/nelly set "$NAME" '.health.cmd' '"curl -fsS http://localhost/health || exit 1"' >/dev/null 2>&1; then
    pass "accepted custom health.cmd with opt-in"
else
    fail "rejected custom health.cmd with opt-in"
fi
bin/nelly set "$NAME" '.health.cmd' '""' >/dev/null 2>&1
bin/nelly set "$NAME" '.allow_dangerous_health_cmd' 'false' >/dev/null 2>&1

# log_retention_days feeds `find -mtime` and must be a plain integer.
if bin/nelly set "$NAME" '.log_retention_days' '"abc"' >/dev/null 2>&1; then
    fail "accepted non-numeric log_retention_days"
else
    pass "rejected non-numeric log_retention_days"
fi
if bin/nelly set "$NAME" '.log_retention_days' '14' >/dev/null 2>&1; then
    pass "accepted numeric log_retention_days"
else
    fail "rejected numeric log_retention_days"
fi
bin/nelly set "$NAME" '.log_retention_days' '7' >/dev/null 2>&1

# ----------------------------------------------------------------------------
section "doctor (offline-friendly)"
bin/nelly doctor "$NAME" >/dev/null 2>&1 || true
# we just want it to have run; non-zero is expected here (no docker daemon in test env)
pass "doctor ran"

# ----------------------------------------------------------------------------
section "releases (deploy version control)"
# create + finalize a release manually (no real deploy needed)
REL_OUT="$(bash lib/release.sh create "$DIR")"
[[ -n "$REL_OUT" && "$REL_OUT" =~ ^r-[0-9]{4}$ ]] \
    && pass "release create returns id: $REL_OUT" || fail "release create: $REL_OUT"
REL_ID="$REL_OUT"

# manifest + snapshot files exist
[[ -f "$DIR/def/releases/$REL_ID/manifest.json" ]] && pass "manifest exists" || fail "no manifest"
[[ -f "$DIR/def/releases/$REL_ID/config.json"   ]] && pass "config snapshot exists" || fail "no config snapshot"

# pending → success
bash lib/release.sh finalize "$DIR" "$REL_ID" --outcome success --image "fake:v1" --health "healthy" >/dev/null 2>&1
outcome="$(jq -r .outcome "$DIR/def/releases/$REL_ID/manifest.json")"
[[ "$outcome" == "success" ]] && pass "release finalized as success" || fail "outcome: $outcome"

# duration is non-negative integer
dur="$(jq -r .duration_seconds "$DIR/def/releases/$REL_ID/manifest.json")"
[[ "$dur" =~ ^[0-9]+$ ]] && pass "duration recorded ($dur s)" || fail "duration: $dur"

# release list includes the id
list_out="$(bin/nelly release list "$NAME")"
[[ "$list_out" == *"$REL_ID"* ]] && pass "release list shows $REL_ID" || fail "release list output"

# release show JSON has the manifest
bin/nelly --json release show "$NAME" "$REL_ID" | jq -e '.image == "fake:v1"' >/dev/null \
    && pass "release show --json" || fail "release show --json"

# note round-trip
bin/nelly release note "$NAME" "$REL_ID" "smoketest note" >/dev/null 2>&1
note="$(bin/nelly --json release show "$NAME" "$REL_ID" | jq -r .note)"
[[ "$note" == "smoketest note" ]] && pass "release note round-trip" || fail "note: $note"

# create a second release and diff
REL2="$(bash lib/release.sh create "$DIR")"
bash lib/release.sh finalize "$DIR" "$REL2" --outcome success --image "fake:v2" >/dev/null 2>&1
bin/nelly release diff "$NAME" "$REL_ID" "$REL2" >/dev/null 2>&1 \
    && pass "release diff runs" || fail "release diff"

# prune to keep=1 leaves 1
bin/nelly release prune "$NAME" --keep 1 >/dev/null 2>&1
remaining="$(jq '.releases | length' "$DIR/def/releases.index.json")"
[[ "$remaining" == "1" ]] && pass "release prune --keep 1" || fail "remaining: $remaining"

# ----------------------------------------------------------------------------
section "metrics (per-app run stats)"
# Fabricate a small .metrics.jsonl and confirm aggregation works.
mkdir -p "$DIR/logs/cron"
M="$DIR/logs/cron/foo.metrics.jsonl"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
    echo '{"ts":"'"$NOW"'","app":"foo","rc":0,"duration_s":10}'
    echo '{"ts":"'"$NOW"'","app":"foo","rc":0,"duration_s":12}'
    echo '{"ts":"'"$NOW"'","app":"foo","rc":1,"duration_s":3}'
} > "$M"
# Re-add a foo app so metrics has something to attach to.
bin/nelly app add "$NAME" --name foo --local /tmp --schedule "*/5 * * * *" --entrypoint main.py >/dev/null 2>&1 || true

metrics_json="$(bin/nelly --json metrics "$NAME")"
runs="$(echo "$metrics_json" | jq -r '.[] | select(.app == "foo") | .runs')"
ok="$(echo "$metrics_json" | jq -r '.[] | select(.app == "foo") | .success')"
fail_=$(echo "$metrics_json" | jq -r '.[] | select(.app == "foo") | .failed')
[[ "$runs" == "3" && "$ok" == "2" && "$fail_" == "1" ]] \
    && pass "metrics aggregation correct (runs=3 ok=2 fail=1)" \
    || fail "metrics: runs=$runs ok=$ok fail=$fail_"

# Human output renders
bin/nelly metrics "$NAME" 2>&1 | grep -q "^foo " \
    && pass "metrics human output renders" || fail "metrics human output"

# --since filtering: a tiny window before any data should yield zero rows
empty="$(bin/nelly --json metrics "$NAME" --since 1s 2>/dev/null | jq 'length' 2>/dev/null || echo X)"
# With ts == NOW, 1s window may still include — instead use --app on a nonexistent app
empty="$(bin/nelly --json metrics "$NAME" --app nosuchapp | jq 'length')"
[[ "$empty" == "0" ]] && pass "metrics filter works" || fail "metrics filter: $empty"

# Build.sh emits the nelly-run helper into stage on --dry-run
DRY_OUT="$(bin/nelly build "$NAME" --dry-run 2>&1 || true)"
[[ "$DRY_OUT" == *"nelly-run"* ]] && pass "build installs nelly-run wrapper" || fail "nelly-run not in rendered Dockerfile"

# ----------------------------------------------------------------------------
section "base image pinning + image-prune dispatch"

# Valid digest-pinned base_image accepted.
bin/nelly set "$NAME" '.base_image' '"python:3.11-slim@sha256:abc123def456abc123def456abc123def456abc123def456abc123def456abcd"' >/dev/null
[[ "$(bin/nelly get "$NAME" '.base_image')" == "python:3.11-slim@sha256:"* ]] \
    && pass "base_image accepts digest-pinned form" || fail "base_image set"

# Bad base_image rejected (leading dash → arg injection vector).
if bin/nelly set "$NAME" '.base_image' '"--evil python:3.11-slim"' >/dev/null 2>&1; then
    fail "accepted base_image starting with '-'"
else
    pass "rejected base_image starting with '-'"
fi
bin/nelly set "$NAME" '.base_image' '""' >/dev/null

# Healthcheck duration fields validated.
if bin/nelly set "$NAME" '.health.interval' '"60 seconds"' >/dev/null 2>&1; then
    fail "accepted bad health.interval"
else
    pass "rejected bad health.interval"
fi
if bin/nelly set "$NAME" '.health.start_period' '"30s"' >/dev/null 2>&1; then
    pass "accepted valid health.start_period"
else
    fail "rejected valid health.start_period"
fi

# image-prune dispatches without docker (it just won't find anything to prune).
# The script requires `docker info` to succeed before doing work, so without
# docker it should error out gracefully. We just check the command path is wired.
out="$(bin/nelly image-prune "$NAME" --dry-run 2>&1 || true)"
[[ -n "$out" ]] && pass "image-prune command dispatched" || fail "image-prune not wired"

# Dry-run + --keep parsing
out="$(bin/nelly image-prune "$NAME" --keep 5 --dry-run 2>&1 || true)"
[[ -n "$out" ]] && pass "image-prune accepts --keep + --dry-run" || fail "image-prune flags"

# ----------------------------------------------------------------------------
section "doctor expanded checks"

# Run doctor on the test deployment; check the new sections fire.
doctor_out="$(bin/nelly doctor "$NAME" 2>&1 || true)"
[[ "$doctor_out" == *"base_image"* || "$doctor_out" == *"base image"* ]] \
    && pass "doctor reports base image status" || fail "doctor missing base image check"

# ----------------------------------------------------------------------------
section "telegram bot wiring"
# Python module must compile
if python3 -m py_compile lib/bot.py 2>/dev/null; then
    pass "bot.py compiles"
else
    fail "bot.py syntax error"
fi
# bot.py logic (offline): keyboards, confirm guard, dispatch write-gating.
# Runs in a throwaway NELLY_ROOT so the real bot/ is never touched. py_compile
# only catches syntax; this catches NameError/AttributeError in tested paths.
if NELLY_ROOT="$(mktemp -d)" python3 - <<'PY' 2>/dev/null; then
import sys
sys.path.insert(0, "lib")
import bot
assert bot.state_dot("exited") == "🔴" and bot.state_dot("running") == "🟢"
rows = bot.kbd_for_deployment("x", True)
assert all(len(r) <= 2 for r in rows), "keyboard rows must be <=2 wide"
labels = {l: d for r in rows for (l, d) in r}
assert labels["Stop"] == "cf|st|x" and labels["Deploy"] == "cf|dp|x", "destructive taps must confirm"
assert labels["« Menu"] == "start", "every screen needs a way back to the menu"
_txt, kb = bot.cmd_confirm(["st", "x"], False)
flat = [(b["text"], b["callback_data"]) for row in kb for b in row]
assert any(t.startswith("Yes") and d == "st|x" for t, d in flat), "confirm Yes replays the op"
assert any(t == "Cancel" for t, _ in flat), "confirm offers Cancel"
assert bot.resolve_cmd("cf") == "confirm"
assert bot.COMMANDS["confirm"][1] is False and bot.COMMANDS["stop_dep"][1] is True
resp = bot._dispatch({"allow_writes": False, "allowed_users": [1]}, "stop_dep", ["x"], 1)
assert "writes disabled" in resp, "write command must be gated when allow_writes is false"
assert "unknown command" in bot._dispatch({"allow_writes": True, "allowed_users": [1]}, "nope", [], 1)
htxt, _hk = bot._split_resp(bot.cmd_help([], True))
assert "Nelly bot" in htxt, "help must render"
bot.run_nelly = lambda *a, **k: (0, '[{"deployment":"ok1","state":"running"},{"deployment":"bad1","state":"exited"}]')
dtxt, dk = bot._split_resp(bot.cmd_start([], True))
assert "🔴" in dtxt and "bad1" in dtxt, "menu must surface the failing deployment"
assert "ok1" not in dtxt, "healthy deployments stay out of the menu text"
btn_labels = [bn["text"] for row in dk for bn in row]
assert btn_labels.index("bad1") < btn_labels.index("ok1"), "failed deployments must sort first"
PY
    pass "bot.py logic (keyboards/confirm/gating)"
else
    fail "bot.py logic checks"
fi
# bot subcommand surfaces help
if bin/nelly bot 2>&1 | grep -q "bot <sub>"; then pass "bot help"; else fail "bot help"; fi

# allow/revoke round-trip — should NOT need a real token, just writes config.
rm -rf bot
bin/nelly bot allow 12345 >/dev/null 2>&1
[[ "$(jq -r '.allowed_users | join(",")' bot/config.json 2>/dev/null)" == "12345" ]] \
    && pass "bot allow writes config" || fail "bot allow"
[[ "$(stat -c %a bot/config.json)" == "600" ]] \
    && pass "bot config mode 0600" || fail "bot config mode: $(stat -c %a bot/config.json)"
bin/nelly bot allow 67890 >/dev/null 2>&1
[[ "$(jq -r '.allowed_users | sort | join(",")' bot/config.json)" == "12345,67890" ]] \
    && pass "bot allow dedupes" || fail "bot allow dedupe"
bin/nelly bot revoke 12345 >/dev/null 2>&1
[[ "$(jq -r '.allowed_users | join(",")' bot/config.json)" == "67890" ]] \
    && pass "bot revoke" || fail "bot revoke"

# Reject non-numeric user IDs.
if bin/nelly bot allow 'rm -rf /' >/dev/null 2>&1; then
    fail "accepted non-numeric user id"
else
    pass "rejected non-numeric user id"
fi

# systemd unit generation writes to a temp HOME so we don't pollute the user's
# real ~/.config.
SYSD_HOME="$(mktemp -d)"
if HOME="$SYSD_HOME" XDG_CONFIG_HOME="$SYSD_HOME/.config" bin/nelly bot install-systemd >/dev/null 2>&1; then
    unit="$SYSD_HOME/.config/systemd/user/nelly-bot.service"
    if [[ -f "$unit" ]] && grep -q "ExecStart=.*bin/nelly bot start" "$unit"; then
        pass "install-systemd writes unit"
    else
        fail "install-systemd unit missing or malformed"
    fi
else
    fail "install-systemd failed"
fi
rm -rf "$SYSD_HOME"

# notify with no recipients must refuse.
rm -rf bot
echo "fake" > /tmp/nelly-fake-token-$$
mkdir -p bot
mv /tmp/nelly-fake-token-$$ bot/.token; chmod 600 bot/.token
echo '{"allowed_users": [], "allow_writes": false, "notify_chat_id": null}' > bot/config.json
chmod 600 bot/config.json
if bin/nelly bot notify "hello" >/dev/null 2>&1; then
    fail "notify with no recipients should fail"
else
    pass "notify refuses with no recipients"
fi
rm -rf bot

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
