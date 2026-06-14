# Nelly

## Macro
Nelly schedules Python jobs in Docker without a daemon. You give it a Python
source (git repo or local directory), a cron schedule, and an entrypoint; it
produces and runs a Docker container that executes that script on schedule with
isolated per-app virtualenvs, runtime-mounted secrets, pinned commits,
healthchecks, resource limits, persistent logs, host hooks, multi-network
attachment, declarative export/import, backup/restore, fleet snapshots, and a
deploy pipeline with release tracking and auto-rollback. It is a stateless bash
wrapper around `docker` + `git` + `jq`: there is no service of its own — the
"service" is the container it builds. All persistent state lives on disk under
`containers/<deployment>/` and `bot/`. The trust boundary is the per-deployment
`config.json`, treated as code and gated by a validator on every state-changing
command. An optional stdlib-only Telegram bot exposes read-only monitoring and
allow-listed write actions from a phone.

## Project tree
```
Nelly/
├── bin/
│   └── nelly                   # CLI entry point — global flag parsing + subcommand dispatch
├── lib/                        # implementation modules (34 *.sh + bot.py); each invokable standalone
│   ├── common.sh               # sourced shared helpers: logging, locking, jq, output mode
│   ├── config.sh               # validate/show/get/set/edit config + apps + tags
│   ├── wizard.sh               # interactive prompts + init/add-app/add-secrets wizards
│   ├── app.sh                  # `nelly app …` dispatcher
│   ├── secrets.sh              # global + per-app .env management
│   ├── source.sh               # fetch one app's source (git clone / local rsync)
│   ├── fetch.sh                # iterate apps[], fetch all sources, write lockfile
│   ├── build.sh                # render Dockerfile + crontab, build + tag image
│   ├── run.sh                  # docker run with networking/secrets/health/wait+rollback
│   ├── manage.sh               # start/stop/restart/exec/shell/attach/run-now/top/inspect
│   ├── rollback.sh             # switch container to a prior image tag
│   ├── hooks.sh                # run confined lifecycle hook scripts on the host
│   ├── push.sh                 # docker cp a file into a running app
│   ├── stats.sh                # ps / stats over nelly-managed containers
│   ├── list.sh                 # list all deployments + state
│   ├── status.sh               # one deployment's state + pinned commits
│   ├── logs.sh                 # tail per-app cron logs
│   ├── events.sh               # stream docker events for one deployment
│   ├── cron.sh                 # human-readable crontab + next-run preview
│   ├── diff.sh                 # preview what next fetch would change
│   ├── plan.sh                 # preview the full deploy pipeline (no side effects)
│   ├── explain.sh              # plain-English deployment summary
│   ├── doctor.sh               # pre-flight checks
│   ├── metrics.sh              # aggregate per-app run metrics from JSONL
│   ├── release.sh              # create/finalize/list/show/diff/restore/note/prune releases
│   ├── backup.sh               # tarball backup + restore of one deployment
│   ├── snapshot.sh             # fleet-wide off-site restore bundle (quiesce + manifest)
│   ├── portable.sh             # export/import/clone/init-from (JSON, version 1)
│   ├── image-prune.sh          # keep last N successful images per deployment
│   ├── prune.sh                # delete old log + metrics files
│   ├── all.sh                  # multi-deployment dispatcher with --tag filtering
│   ├── update.sh               # `nelly update` self-upgrade pipeline
│   ├── check-updates.sh        # poll upstream branch, notify bot, systemd timer
│   ├── bot.sh                  # Telegram bot management CLI
│   └── bot.py                  # Telegram bot daemon (Python, stdlib only)
├── tests/
│   ├── smoke.sh                # offline assertions; no Docker; ~5 s
│   └── e2e.sh                  # full pipeline against real Docker; skips if absent
├── containers/
│   └── template/               # `nelly init` copies this (reference config + Dockerfile)
│       ├── def/
│       │   ├── config.json     # default config (source of truth shape)
│       │   ├── Dockerfile      # build template with NELLY: placeholders
│       │   ├── cron            # deprecated stub (crontab now assembled at build time)
│       │   └── hooks/
│       │       └── example.sh.disabled
│       ├── apps/               # (empty placeholder; fetched source lands here)
│       └── logs/               # (empty placeholder; cron/build/fetch/run logs land here)
├── .github/
│   └── workflows/
│       └── test.yml            # CI: smoke (offline) + e2e (real docker)
├── install.sh                  # one-shot Debian/Ubuntu bootstrap installer
├── ruff.toml                   # lint config for lib/bot.py (the only Python)
├── README.md                   # concepts, recipes, configuration + security reference
├── INSTALL.md                  # detailed install + post-install guide
└── INTERFACE.md                # `nelly snapshot` backup data contract
```

## Root files
### install.sh
One-shot Debian/Ubuntu bootstrap. Inputs: must run from inside a Nelly checkout
(reads `bin/nelly`), `/etc/os-release`, env `NELLY_SKIP_DOCKER` (skip Docker
install). Output: installs host packages + Docker Engine via `apt`/`sudo`, adds
the user to the `docker` group, symlinks `bin/nelly` into `~/.local/bin`, edits
the shell rc for PATH, verifies `nelly --version`. Idempotent. Errors print
`ERROR: <msg>` to stderr and exit 1.

### ruff.toml
Lint config scoped to `lib/bot.py` (the only Python in the tree). Ignores E701/E702
to allow the bot's compact one-line style; keeps pyflakes (F) checks on.

### README.md / INSTALL.md / INTERFACE.md
Human documentation. README is the concepts/recipes/configuration/security
reference; INSTALL is the install guide; INTERFACE is the `nelly snapshot`
data-contract spec for off-site backup tools. Not loaded by Nelly at runtime.

## Subdirectories
- **bin/** — Single CLI entry point `nelly`: parses global flags, dispatches
  subcommands to `lib/*.sh`, and orchestrates the locked deploy pipeline
  (release create → hooks → fetch → build → run → finalize → prune). Input: argv +
  env (`NELLY_OUTPUT`, `NELLY_YES`, `INTERACTIVE`). Output: delegates to lib;
  exit 2 on unknown command. Has its own CLAUDE.md.
- **lib/** — All implementation. Each script is independently invokable
  (`bash lib/<x>.sh <deploy_dir> …`) and reads/writes deployment state under
  `containers/<name>/def/` and `logs/`. Boundary input: a deployment directory
  and its `config.json`; boundary output: rendered Docker artifacts, the running
  container, lockfile/release/metrics records, and stdout reports (human or JSON
  via `NELLY_OUTPUT`). Has its own CLAUDE.md.
- **tests/** — `smoke.sh` (offline, ~122 assertions, scaffolds throwaway
  `containers/smoketest-*` deployments) and `e2e.sh` (real Docker, full pipeline,
  exits 0 when Docker is absent). Input: the repo itself. Output: pass/fail lines
  + non-zero exit on failure. Has its own CLAUDE.md.
- **containers/** — Per-deployment state lives here at runtime (gitignored).
  Only `template/` is tracked: the reference `def/config.json` + `def/Dockerfile`
  that `nelly init` copies for a new deployment. No proprietary script → no
  CLAUDE.md.
- **.github/workflows/** — `test.yml` runs shellcheck, `py_compile` + ruff on
  `bot.py`, the smoke suite on every push/PR, and the e2e suite on Ubuntu
  runners. Config only → no CLAUDE.md.

## Conventions
- Write correct, efficient bash; every script starts `set -euo pipefail`.
- Keep each `lib/*.sh` independently invokable (`bash lib/<x>.sh <deploy_dir> …`)
  for standalone debugging.
- Build argv arrays; never `eval`. Pass values as positional parameters and never
  interpolate config values or CLI args into program text (see the locked deploy
  subshell in `bin/nelly`).
- `containers/<name>/def/config.json` is the source of truth and is treated as
  code; every state-changing command runs `validate_config` first.
- Use `jq` for all JSON; write secret files at mode 0600 and re-assert it on
  every write.
- Input/output sections describe data, never code.

## Recommended skills
- **context-map-builder** — used to generate these CLAUDE.md files; re-run it when
  the script set or data contracts change so the map stays current.
- No other skill usage detected in the repo or session.

## References
- Task list: TASKS.md
- Preserved human notes: projectNotes.md (per directory, when present)
