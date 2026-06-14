# lib

## Macro
Every piece of Nelly's behavior lives here, one concern per file. `common.sh` is
sourced by the rest for logging, locking, jq access, and output mode; the other
scripts are dispatched by `bin/nelly` (and a few by each other). Each is callable
standalone with a deployment directory as its first argument, so any stage can be
run and debugged in isolation. The shared data contract is the deployment
directory: scripts read `def/config.json` (validated first), the lockfile, and
secrets; they write Docker artifacts, the running container, lockfile/release/
metrics records, and logs under `logs/`. Fatal errors go through `die` (stderr
`[ERROR] <msg>`, exit 1) except `doctor.sh`. `NELLY_OUTPUT=json` switches machine
output for list, status, events, cron, diff, metrics, release, stats, snapshot —
but not plan, explain, or doctor (human-only).

## Files

### common.sh
Sourced library of shared helpers (not executed). Inputs: env `NELLY_ROOT`
(required by `deployment_dir`/`list_deployments`/`container_name_for`), `NELLY_YES`
+ `INTERACTIVE` (gate `confirm`), `NELLY_OUTPUT` (`json`|`human`); function args
for `jqget <file> <expr> [default]`, `jq_inplace <file> <expr>`, `with_lock
<deploy_dir> <cmd…>`, `require_cmd <cmd…>`, `log_to <file>`. Outputs: `info/warn/
err/die` write timestamped colorized lines to stderr (`die` exits 1); `jqget`/
`deployment_dir`/`container_name_for` print resolved values to stdout; `jq_inplace`
atomically rewrites the target JSON; `with_lock` uses `<deploy_dir>/.nelly.lock`
and returns the wrapped command's exit code.

### config.sh
Validate, read, and edit a deployment's `def/config.json` (apps, schedules, tags).
Inputs: `<deploy_dir>` plus a subcommand — `validate|show|get <jq-path>|set
<jq-path> <value>|edit|add-app|remove-app|set-schedule|tags-list|tags-add|
tags-remove`; reads `def/config.json`; env `EDITOR`/`VISUAL` (default nano).
Outputs: `show`/`get`/`tags-list` print to stdout; mutating subcommands rewrite
`def/config.json` in place (snapshot + restore on validation failure). On
validation failure prints `config validation failed for <config>:` plus one
`  - <message>` per error and returns 1; other errors via `die`.

### wizard.sh
Interactive prompt primitives + the `init`/`add-app`/`add-secrets` setup wizards.
Inputs: `<deploy_dir>`, stdin prompts (secret values read hidden), env `NELLY_YES`
(auto-accept defaults, die on missing required value). Outputs: prompts/banners/
app-preview JSON to stderr; writes `.container_name`/`.image_name`/`.apps[]` into
`def/config.json` (delegating to `config.sh set` and `wizard_add_app`) and secrets
via `secrets.sh`. Errors via `die`.

### app.sh
`nelly app …` dispatcher for one deployment. Inputs: `<sub> <deploy_dir> [args]`
where sub ∈ `add|list|show <app>|remove <app>|schedule <app> <cron>|ref <app>
<git-ref>|path <app> <local-path>`; reads `def/config.json`; env `NELLY_OUTPUT`.
Outputs: `list` prints a table or `.apps` JSON; `show` prints the app object;
`ref`/`path` rewrite `.apps[i].source.*` via `jq_inplace`. Usage errors print to
stdout and exit 2; others via `die` (e.g. "no such app").

### secrets.sh
Manage deployment-wide `def/.env` and per-app `def/secrets/<app>.env`. Inputs:
`<sub> <deploy_dir> [--app A] …` where sub ∈ `set|unset|list|edit|template`; keys
must match `^[A-Za-z_][A-Za-z0-9_]*$`; reads `def/config.json` to validate
`--app`; env `NELLY_OUTPUT`, `EDITOR`/`VISUAL`. Outputs: writes `KEY="value"`
lines (files mode 0600, `secrets/` mode 0700); `list` prints key names only;
`template` prints `ENV_*=` skeleton from legacy `.apps[].env`. Errors via `die`.

### source.sh
Fetch one app's source (git clone or local rsync) and emit the resolved revision.
Inputs: `fetch_source <app-json> <target_dir>` / `normalize <app-json>`; app-json
carries `.source{type:git,url,ref}` or `{type:local,path}` (legacy `git_url`/`ref`/
`branch` accepted); requires `git`+`rsync`. Outputs: repopulates `<target_dir>`
(rsync, excluding `.git`/caches); prints exactly one revision-id line to stdout
(git SHA, or `local:<ts>` / `local:<sha>` for non-git local). Errors via `die`.

### fetch.sh
Orchestrator: fetch every app's source into `apps/` and pin revisions. Inputs:
`<deploy_dir>`; reads `def/config.json` (`.apps[]`), `def/commits.lock.json`
(created `{}` if absent); runs `validate_config`. Outputs: populates
`apps/<app>/` per app; rewrites `def/commits.lock.json` as `{ "<app>": "<rev>" }`
(pruning removed apps); all output tee'd to `logs/fetch.log`. Errors via `die`.

### build.sh
Render the Dockerfile + crontab from config and build/tag the image. Inputs:
`<deploy_dir>` + optional `--dry-run`; reads `def/config.json` (`.image_name`,
`.base_image`, `.apps[].{app_name,schedule,entrypoint}`, `.packages[]`),
`def/Dockerfile` template (`NELLY: SYSTEM_PACKAGES` / `NELLY: APP_VENVS`
placeholders), `def/commits.lock.json` (hashed for the tag), per-app
`requirements.txt`. Outputs: `.build/` artifacts (crontab, fragments, context),
`def/last_image.txt` (`image:tag`), appends `def/build_history.json` (capped 50);
tags `:<lockfile-sha12>` + `:<UTC-datestamp>` + `:latest`; output to
`logs/build.log`. Errors via `die`.

### run.sh
(Re)create and start the container. Inputs: `<deploy_dir>` + `--image <tag>` /
`--wait-healthy [N]` / `--auto-rollback`; reads `def/config.json` (`.container_name`,
`.network.*`, `.resources.*`, `.health.*`, `.volumes[]`, `.restart`, `.tags`),
`def/last_image.txt`, `def/.env`, `def/secrets/`. Outputs: runs a detached
container with `nelly.*` labels, bind-mounting `.env`→`/etc/nelly/global.env:ro`,
`secrets`→`/etc/nelly/secrets:ro`, `logs/cron`→`/var/log/nelly`; on failed
`--wait-healthy` with `--auto-rollback` re-execs with the previous tag, else
exits 1; output to `logs/run.log`. Errors via `die`/`err`.

### manage.sh
Container lifecycle dispatcher. Inputs: `<sub> <deploy_dir> [args]` where sub ∈
`start|stop|restart|exec [-- cmd…]|shell [--app A]|attach|run-now <app>|top|
inspect`; reads `def/config.json` (`.apps[].{app_name,entrypoint}`) for
`shell --app`/`run-now`; env `NELLY_OUTPUT` (for `inspect`). Outputs: docker
passthrough to stdout; `run-now` invokes in-container `nelly-run`, tails new
`<app>.log` bytes, and propagates the job's exit code (re-validates entrypoint
`^[A-Za-z0-9_./-]+$`). Usage → exit 2; others via `die`.

### rollback.sh
Switch the container to a prior image tag, or list build history. Inputs:
`<deploy_dir>` + `--to <tag>` / `--list`; reads `def/build_history.json`
(required); env `NELLY_OUTPUT`. Outputs: `--list` prints history (JSON or
`<built_at>  <image>` lines); a rollback wraps `release.sh create` →
`run.sh --image <tag>` → on success writes `def/last_image.txt` and
`release.sh finalize --outcome rolled_back`, on failure finalizes `failed` and
`die`s.

### hooks.sh
Resolve and run a confined lifecycle hook on the host. Inputs (sourced as
`run_hook`, or executed): `<deploy_dir> <hook_name>` where name ∈ `pre_deploy|
post_deploy|on_failure|pre_snapshot|post_snapshot`; reads `def/config.json`
`.hooks.<name>` (path), optional `def/last_image.txt`. Outputs: executes the hook
with env `NELLY_DEPLOYMENT`/`NELLY_DEPLOY_DIR`/`NELLY_HOOK`/`NELLY_IMAGE` (+
`NELLY_SNAPSHOT_DIR` for snapshot hooks). Rejects absolute/`..`/escaping/
non-executable paths (warns, returns 0); a non-zero hook returns its exit code
for the caller to decide.

### push.sh
Hot-copy a local file/dir into a running app (ephemeral until next deploy).
Inputs: `<deploy_dir> <app> <src> [dst]`; `src` must exist. Outputs: `docker cp`
into the container; default dst `/home/apps/<app>/<basename>`, relative dst
prefixed with `/home/apps/<app>/`. Errors via `die` (e.g. container not running).

### stats.sh
`ps`/`stats` views filtered to nelly-managed containers (label
`nelly.managed=true`). Inputs: `$1` sub (`ps` default | `stats`); env
`NELLY_OUTPUT`. Outputs: `ps` lists all such containers (JSON array or table);
`stats` runs one-shot `docker stats --no-stream` over running ones, or prints
`info "no running nelly containers"`. Unknown sub → `die`.

### list.sh
List every deployment with container state, image, app count. Inputs: none
positional; env `NELLY_ROOT` (required), `NELLY_OUTPUT`; reads each
`containers/<name>/def/config.json` + `last_image.txt`; queries `docker inspect`.
Outputs (stdout): JSON array `{deployment,container,state,image,apps}` or a
table; skips `template`. Errors via `die`.

### status.sh
One deployment's runtime state, image, schedules, pinned commits. Inputs:
`<deploy_dir>`; reads `def/config.json`, `def/commits.lock.json` (default `{}`),
`def/last_image.txt`; env `NELLY_OUTPUT`. Outputs (stdout): JSON
`{container,state,health,started,image,pinned,schedules}` or labeled human lines.
Errors via `die`.

### logs.sh
Tail per-app cron logs. Inputs: `<deploy_dir> [app]`; reads `logs/cron/<app>.log`
or all `logs/cron/*.log`. Outputs: `exec`s `tail -F` (long-running stream on
stdout). `die`s if the named log or any `*.log` is missing.

### events.sh
Stream `docker events` for one deployment's container. Inputs: `<deploy_dir>` +
`--since <value>`; env `NELLY_OUTPUT`. Outputs: prints an `info` line then
`exec`s `docker events` (long-running; JSON `{{json .}}` or `Time Action exit
image` human format).

### cron.sh
Show the assembled per-app schedule in English, optionally with next runs.
Inputs: `<deploy_dir>` + `--next <N>`; reads `def/config.json`
(`.apps[].{app_name,schedule,entrypoint}`); env `NELLY_OUTPUT`; optional host
`python3` for next-run computation (degrades gracefully). Outputs (stdout): JSON
`[{app,schedule,entrypoint,description,next_runs}]` or an `APP/SCHEDULE/WHEN`
table. Errors via `die`.

### diff.sh
Show what the next fetch would change (lockfile vs freshly resolved refs).
Inputs: `<deploy_dir>`; reads `def/config.json` (`.apps[]`) +
`def/commits.lock.json`; runs `validate_config` + `normalize_app_source`;
resolves git refs via `git ls-remote`; env `NELLY_OUTPUT`. Outputs (stdout): one
line per app (`name: old → new` / `up-to-date (sha)` / `(local, always
re-synced)`), JSON-wrapped when `json`; creates an empty lockfile if missing.

### plan.sh
Side-effect-free preview of what `nelly deploy` would do. Inputs: `<deploy_dir>`;
reads `def/config.json` (container/image/apps/packages/resources/network/
retention) + `def/commits.lock.json`, counts `def/.env` keys; runs
`validate_config`; resolves refs via `git ls-remote`. Output: a four-section
fetch/build/run/prune plan to stdout (human-only; `NELLY_OUTPUT` not consumed).
Errors via `die`.

### explain.sh
Plain-English deployment summary. Inputs: `<deploy_dir>`; reads `def/config.json`
(container/image/apps/sources/schedules/resources/network) and counts `def/.env`
keys. Output: a formatted summary + `Apps` section to stdout (human-only).
Errors via `die`.

### doctor.sh
Pre-flight checks before deploying. Inputs: `<deploy_dir>`; reads `def/config.json`,
`def/.env`, `def/secrets/*.env`, `apps/<app>/{entrypoint,requirements.txt}`,
`$NELLY_ROOT/bot/{config.json,.token}`; probes `git ls-remote`, `docker info`,
host tools, file modes. Output: colorized `✓`/`!`/`✗` lines + summary to stdout;
exit 0 if no problems else exit 1. Uses local `ok`/`warn_`/`bad` (not `die`).

### metrics.sh
Aggregate per-app run metrics. Inputs: `<deploy_dir>` + `--app A` / `--since DUR`
(`Ns|Nm|Nh|Nd`) / `--release REL`; reads `logs/cron/*.metrics.jsonl` (lines
`{ts,app,rc,duration_s}`) and `def/releases.index.json` for `--release`; env
`NELLY_OUTPUT`. Outputs (stdout): JSON array `{app,runs,success,failed,last_ts,
last_rc,avg_dur_s,max_dur_s,p95_dur_s}` or an `APP/RUNS/OK/FAIL/AVG/P95/LAST/RC`
table. Errors via `die`.

### release.sh
Manage release records (one per deploy). Inputs (sourced or CLI): `create
<deploy_dir>`, `finalize <deploy_dir> <rel_id> --outcome S [--image|--health|
--wait-healthy|--rollback-of|--auto-rolled-back]`, `list|show|diff|restore|note|
prune <deploy_dir> …`; reads `def/config.json`, `commits.lock.json`,
`last_image.txt`, `def/releases.index.json`, per-release `manifest.json`; env
`USER`, `NELLY_OUTPUT`. Outputs: `create` echoes the new `rel_id` (`r-%04d`) and
writes `def/releases/<rel_id>/{manifest.json,config.json,commits.lock.json}` +
updates the index; `finalize` rewrites the manifest and copies `logs/{build,run}.log`
(prunes to keep 50); `list`/`show` tables or JSON; `diff` a unified config diff.
Errors via `die`.

### backup.sh
Tarball backup + restore of one deployment. Inputs: `backup <deploy_dir> [--out
PATH] [--include-logs] [--include-secrets] [--no-compress] [--deterministic]
[--quiet]` or `restore <tarball> [--as <name>] [--force]`; env `NELLY_ROOT`.
Outputs: `backup` writes a tar(.gz) (excludes `apps/`, `.build`, lock, and by
default `logs/`/secrets) to `--out` or `<name>-<UTC-ts>.tar[.gz]`; `restore`
extracts into `containers/<name>`, recreates `apps/`+`logs/cron`, rewrites
names if `--as`, re-validates, chmod 600 secrets. Errors via `die`; unknown sub
→ exit 2.

### snapshot.sh
Build the fleet-wide off-site restore bundle. Inputs: `create [--out DIR]
[--no-quiesce|--no-volumes|--no-secrets|--no-verify] [--only N]… [--exclude N]…
[--quiesce-time N]`, `verify|list [--out DIR]`, `install-hook|uninstall-hook
[--hook-dir DIR] [--name NAME]`; reads each deployment's config/lockfile/secrets,
declared `.volumes[]` + `.backup.skip_volumes`, and Docker; env `NELLY_BACKUP_DIR`
(default `/var/backups/nelly`), `NELLY_RESTIC_HOOK_DIR`, `NELLY_OUTPUT`; sources
`hooks.sh`. Outputs: bundle at `$OUT` (mode 0700) with `BUNDLE_VERSION`,
`snapshot.json`, `fleet-manifest.json`, per-deployment `tarball.tar` +
`container-inspect.json` + `image-digest.txt` + quiesced `volumes/<slug>.{tar,
meta.json}` + `dumps/`, and `nelly-state/{bot.tar,nelly-commit.txt}`; built in
`<out>.new` then swapped atomically. Exit: 0 ok, 1 a deployment failed, 3 verify
failed; an EXIT/INT/TERM trap restarts any stopped container.

### portable.sh
Export/import/clone deployments as JSON (version 1). Inputs: `export <deploy_dir>
[--include-secrets] [--include-lockfile]`, `import <path|-> [--as N] [--force]`,
`clone <src_dir> <new_name>`, `init-from <path> <new_name>`; env `NELLY_ROOT`.
Outputs: `export` prints `{nelly_export_version,deployment,exported_at,config,
secrets_included[,lockfile,secrets_b64]}` to stdout; `import`/`clone`/`init-from`
scaffold `containers/<new_name>` from the template, write config (+ lockfile/.env
mode 600), re-validate. Unsupported version (≠1) / bad name / existing dest
without `--force` → `die`; unknown sub → exit 2.

### image-prune.sh
Remove old Docker images for one deployment. Inputs: `<deploy_dir> [--keep N]
[--dry-run]`; reads `def/config.json` (`.image_name`), `def/releases.index.json`
+ per-release `manifest.json` (`.image`); env `NELLY_IMAGE_KEEP` (default 2);
queries Docker. Outputs: deletes image tags (keeps `:latest` + running + last N
successful), or lists candidates on `--dry-run`; progress via `info`/`warn`.
`die`s on non-numeric `--keep` or missing config.

### prune.sh
Delete old log + metrics files. Inputs: `<deploy_dir>`; reads `def/config.json`
`.log_retention_days` (default 7). Outputs: deletes `logs/**/*.log` and
`*.metrics.jsonl` older than the window (deleted paths printed to stdout);
exits 0 early if `logs/` is absent.

### all.sh
Run one `nelly <cmd>` across all (or tag-filtered) deployments. Inputs: `<cmd>`
+ `[--tag T]…` (AND-ed) + `[--fail-fast]` + `[-- <cmd-args>…]`; reads each
`config.json` `.tags[]`; env `NELLY_ROOT`; invokes `bin/nelly`. Outputs: `list`
prints a `DEPLOYMENT/TAGS` table; otherwise runs per match with `==> <name>`
headers. Exit 1 if any deployment fails (immediate under `--fail-fast`), exit 2
if no command given.

### update.sh
The `nelly update` self-upgrade pipeline. Inputs: `[--check]`, `-i`/`-y`; operates
on the git repo at `$NELLY_ROOT` (needs a clean tree tracking `origin/<branch>`);
classifies changed files to decide bot-restart vs rebuild vs re-run; checks
`systemctl --user is-active nelly-bot`. Outputs: `git pull --ff-only`, runs
`tests/smoke.sh` (abort + revert instructions on failure), then conditionally
restarts the bot and runs `bin/nelly deploy … --wait-healthy 60 --auto-rollback`
or `bin/nelly run …` per deployment (prompted unless `-y`); `--check` prints the
plan only. Preconditions via `die`.

### check-updates.sh
Poll the upstream branch for new commits and optionally notify the bot. Inputs:
`check [--notify] [--branch NAME]`, `install-timer [--every DUR]`,
`uninstall-timer`, `status`; reads state file `$NELLY_ROOT/.update-check.state`
(last-notified SHA); env `NELLY_UPDATE_BRANCH`, `XDG_CONFIG_HOME`/`HOME`; shells
to `bin/nelly bot notify` and `systemctl --user`. Outputs: `check` exit 0
up-to-date / 1 behind / 2 error, with `--notify` sending one idempotent Telegram
message and updating the state file; `install-timer` writes user systemd
`.service`/`.timer`; `status` prints timer + SHA state. Errors via `die`.

### bot.sh
Telegram bot management CLI. Inputs: `setup|start|status|notify <msg>|test|allow
<id>|revoke <id>|install-systemd`; state dir `$NELLY_ROOT/bot/` — `.token` (0600),
`config.json` (`{allowed_users:[int],allow_writes:bool,notify_chat_id}`),
`bot.log`; calls the Telegram API via `curl`; env `NELLY_ROOT`, `XDG_CONFIG_HOME`/
`HOME`, `USER`. Outputs: `setup` writes `.token`/`config.json`; `start` `exec`s
`python3 lib/bot.py`; `notify`/`test` send messages; `allow`/`revoke` rewrite
`.allowed_users`; `install-systemd` writes `~/.config/systemd/user/nelly-bot.service`;
`status` prints PID + config + recent log. Errors via `die`/`err`; unknown sub
→ exit 2.

### bot.py
Telegram bot daemon (Python, stdlib only). Inputs: env `NELLY_ROOT` (required);
reads `bot/.token` (validated `^\d+:[A-Za-z0-9_-]{30,}$`) and `bot/config.json`
(reloaded each poll, last-good kept on bad JSON); long-polls Telegram
`getUpdates`; serves only `allowed_users`; validates args against strict regex
before running `bin/nelly` via `subprocess.run([...], shell=False)` with
`NELLY_OUTPUT` + `NELLY_YES=1`; also reads `containers/<dep>/def/releases.index.json`
and tails logs. Outputs: HTML messages via `sendMessage` (truncated ~3800 chars,
inline keyboards, plaintext fallback) + `answerCallbackQuery`; appends an audit
log to `bot/bot.log` (and stderr). Write commands gated on `allow_writes` + a
two-tap confirm; `die()` logs and exits 1; the main loop retries on network/
handler errors and exits cleanly on SIGINT/SIGTERM.

## Subdirectories
None.
