# Nelly

**Schedule Python jobs in Docker, painlessly.**

You give Nelly a Python source (git repo *or* a local directory), a cron
schedule, and an entrypoint. It produces a Docker container that runs
your script on that schedule — with isolated dependencies, runtime-mounted
secrets, pinned commits, healthchecks, resource limits, and persistent
logs. One CLI manages the whole lifecycle: setup, deploy, update,
rollback, exec, logs.

```
   sources              schedule + entrypoint              container
┌───────────┐         ┌──────────────────────┐         ┌─────────────┐
│ git repo  │         │  apps[].schedule     │         │  cron -f    │
│ or local  │─fetch──▶│  apps[].entrypoint   │─build──▶│  /opt/venvs │
│ directory │         │  apps[].source       │         │  per-app    │
└───────────┘         └──────────────────────┘         └─────────────┘
```

---

## Two ways to drive it

Nelly is built so you can use whichever fits your moment:

**1. Guided CLI** — `nelly init` walks you through setup, `nelly app add` is
   interactive when you don't pass flags, `nelly explain` and `nelly doctor`
   show you what you've got and what to fix.

**2. Edit config.json directly** — the file under `containers/<name>/def/config.json`
   is the source of truth. `nelly edit` opens it in your editor and
   validates it on save. `nelly deploy` picks up any change. Every other
   command is convenience.

Most people start with (1) and graduate to (2). They compose — you can
mix freely.

---

## Contents

1. [Install](#install)
2. [Five-minute tutorial (guided)](#five-minute-tutorial-guided)
3. [Editing config.json directly](#editing-configjson-directly)
4. [Concepts](#concepts)
5. [Command map](#command-map)
6. [Recipes](#recipes)
7. [Configuration reference](#configuration-reference)
8. [Architecture](#architecture)
9. [Troubleshooting](#troubleshooting)
10. [Development](#development)

---

## Install

Requirements (host): Docker 20+, `bash`, `jq`, `git`, `rsync`. Optional: `flock`
(safe concurrency), `shellcheck` (development).

```sh
git clone <this-repo> ~/nelly
cd ~/nelly
ln -s "$PWD/bin/nelly" ~/.local/bin/nelly   # optional — puts `nelly` on $PATH
nelly                                       # short intro + happy-path commands
```

Nelly is a stateless wrapper around `docker` + `git` + `jq`. All persistent
state lives under `containers/<deployment>/`.

---

## Five-minute tutorial (guided)

Each step matches one CLI command. Run them in order.

```sh
# 1. Scaffold a deployment. Walks you through:
#       - container name (default: scraper)
#       - image name     (default: scraper)
#       - add an app now?  → runs the app-add wizard
#       - add secrets now? → asks for KEY/value pairs
nelly init scraper

# 2. Preview what's configured.
nelly explain scraper

# 3. Pre-flight checks: config valid? git reachable? docker running?
nelly doctor scraper

# 4. Build the image and start the container. Non-interactive by default.
nelly deploy scraper

# 5. See it run.
nelly status scraper
nelly logs   scraper          # tail every app's cron output
nelly stats                   # live cpu / memory / pids
```

### What `nelly init` asks you

```
Setting up deployment 'scraper'
Press Enter to accept the default in [brackets]. Ctrl-C to abort.

Container name?       [scraper]
Image name?           [scraper]
Add an app now?       [Y/n]
  App name?           scraper-fetcher
  Where does the code come from?
    1) Git repository (clone at a ref)
    2) Local directory (rsync from a path on this host)
  Git URL?            git@github.com:me/scraper.git
  Branch / tag / commit SHA?  [main]   v1.4.0
  Cron schedule?      [*/5 * * * *]
  Entry point?        [main.py]        run.py
  About to add this app: {...preview...}
  Looks good?         [Y/n]

Add secrets now (DB passwords, API keys, …)? [y/N] y
  Key name (or Enter to stop)?  DB_HOST
  Value for DB_HOST (hidden)?
  Key name (or Enter to stop)?  DB_PASS
  Value for DB_PASS (hidden)?
  Key name (or Enter to stop)?
```

Want to skip the wizard? `nelly -y init scraper` accepts every default and
adds no apps; do `nelly app add scraper` and `nelly secrets set scraper KEY=…`
afterwards.

---

## Editing config.json directly

If you'd rather type once and be done with it, the config-file path is fully
supported.

```sh
nelly init scraper -y               # just scaffold the deployment skeleton
nelly edit scraper                  # opens def/config.json in $EDITOR; validates on save
nelly doctor scraper                # sanity-check before going live
nelly deploy scraper                # picks up any change in config.json
```

Equivalently, any external editor (`vim def/config.json`, IDE, etc.) is fine.
The validator runs on every Nelly command that reads the config (`fetch`,
`build`, `run`, `deploy`, `explain`, `doctor`), so a bad change is rejected
with a clear message rather than producing a broken container.

You can mix the two workflows freely — `nelly app add` writes to config.json
just like your editor does.

---

## Concepts

### Deployments
A **deployment** is one directory under `containers/`. It holds a config, the
fetched source for each app, the secrets, build artefacts, and logs. One
deployment ⇒ one Docker container.

```
containers/scraper/
├── def/
│   ├── config.json           # source of truth — apps, schedules, resources
│   ├── .env                  # secrets (mode 0600, mounted via --env-file)
│   ├── Dockerfile            # template; Nelly renders it at build time
│   ├── commits.lock.json     # which revision each app was fetched at
│   ├── build_history.json    # recent builds (rollback uses this)
│   └── last_image.txt        # image currently in service
├── apps/<app>/               # fetched source per app
└── logs/
    ├── cron/<app>.log        # per-app cron output (bind-mounted)
    ├── fetch.log build.log run.log
```

### Apps
An **app** is one entry under `apps[]` — one scheduled Python script. Each
declares: name, source (git or local), schedule (cron), entrypoint.

Apps inside the same deployment share the OS image but get **isolated
virtualenvs** under `/opt/venvs/<app>`. One app's dependencies cannot
break another's.

### Sources
Two source types are first-class:

```jsonc
// pinned to a git ref (branch, tag, or commit SHA)
"source": { "type": "git", "url": "git@github.com:me/scraper.git", "ref": "v1.4.0" }

// a directory on this host — re-synced on every fetch (great for local dev)
"source": { "type": "local", "path": "/home/me/dev/scraper" }
```

Both are recorded in `commits.lock.json` so every build is reproducible. For
local sources, the lockfile records the directory's git HEAD SHA when
available, or a content hash otherwise.

### Secrets
`def/.env` is mounted via `--env-file` at runtime — **never copied into the
image**. Manage it through `nelly secrets …` so the file stays at mode 0600
and your quoted values survive round-tripping.

### Reproducibility
Every build is tagged with `<image>:<lockfile-hash>` AND `<image>:<timestamp>`
AND `<image>:latest`. `nelly rollback <name>` swaps to the previous tag;
`--to <tag>` picks any specific build; `--list` shows what's available.

### Locking
Every state-changing command takes a per-deployment `flock`. Two concurrent
`nelly deploy`s queue rather than trampling each other.

---

## Command map

`nelly --help` is authoritative. This is the quick map by topic.

### Get started
- `nelly init <name>` — interactive setup wizard
- `nelly explain <name>` — plain-English summary of the deployment
- `nelly doctor <name>` — sanity checks before deploying

### Deploy / update
- `nelly deploy <name>` — fetch → build → run → prune (one shot)
- `nelly fetch <name>` — refresh sources only
- `nelly build <name> [--dry-run]` — build image (or render Dockerfile)
- `nelly run <name>` — (re)start the container
- `nelly diff <name>` — what would change on next fetch?
- `nelly rollback <name> [--to TAG | --list]` — switch back to a prior build
- `nelly push <name> <app> <src> [dst]` — hot-copy a file into a running app

### Manage apps
- `nelly app add <name>` — wizard if no flags given
- `nelly app add <name> --name N (--git URL [--ref R] | --local PATH) --schedule "…" --entrypoint FILE`
- `nelly app list <name>`
- `nelly app show <name> <app>`
- `nelly app remove <name> <app>`
- `nelly app schedule <name> <app> "<cron>"`
- `nelly app ref <name> <app> <git-ref>`
- `nelly app path <name> <app> <local-path>`

### Manage config (file is source of truth)
- `nelly edit <name>` — opens config.json in $EDITOR (validates on save)
- `nelly show <name>` — print full config
- `nelly get <name> <jq-path>` — read one value
- `nelly set <name> <jq-path> <value>` — write one value (JSON-typed if it parses)
- `nelly validate <name>` — lint the config file

### Manage secrets
- `nelly secrets set <name> KEY=value [...]` — add/replace
- `nelly secrets set <name> KEY` — prompt for value (hidden)
- `nelly secrets unset <name> KEY [...]`
- `nelly secrets list <name>` — keys only, never values
- `nelly secrets edit <name>` — open .env in $EDITOR
- `nelly secrets template <name>` — skeleton from legacy `env:` references

### Lifecycle
- `nelly start <name>` / `stop` / `restart`
- `nelly exec <name> -- <cmd...>`
- `nelly shell <name>`
- `nelly run-now <name> <app>` — execute one app immediately, outside cron
- `nelly inspect <name>` — resources / image / health

### Observe
- `nelly list` (alias `ls`) — all deployments + state
- `nelly ps` — docker ps over nelly-managed containers
- `nelly stats` — live cpu / memory / pids
- `nelly status <name>` — one deployment's status + pinned commits
- `nelly logs <name> [app]` — tail container logs
- `nelly prune <name>` — delete logs older than `log_retention_days`

### Global flags
- `--json` — machine-readable output where supported
- `-i, --interactive` — prompt before destructive ops (replace, rollback…)
- `-y, --yes` — never prompt; accept wizard defaults

---

## Recipes

### Update an app to a new release
```sh
nelly app ref scraper fetcher v1.5.0     # or: nelly edit scraper
nelly diff   scraper                     # preview the change
nelly deploy scraper
```

### Change only a schedule (no rebuild needed at runtime, but redeploy regenerates the crontab)
```sh
nelly app schedule scraper fetcher "*/2 * * * *"
nelly deploy scraper
```

### Roll back to the previous build
```sh
nelly rollback scraper --list           # see recent builds
nelly rollback scraper                  # one step back
nelly rollback scraper --to scraper:abc123def4
```

### Develop against a local directory (no git push needed)
```sh
nelly app add scraper \
    --name dev \
    --local /home/me/dev/scraper \
    --schedule "*/2 * * * *" \
    --entrypoint main.py
nelly deploy scraper
```

`local` sources are rsynced on every fetch; just `nelly deploy` to pick up
your latest edits. Or hot-patch one file:

```sh
nelly push scraper dev ./run.py
nelly run-now scraper dev               # execute immediately
# Ephemeral until next deploy.
```

### Cap resources
```sh
nelly set scraper '.resources.cpus'   '0.5'
nelly set scraper '.resources.memory' '256m'
nelly set scraper '.resources.pids_limit' '128'
nelly deploy scraper
```

### Add another scheduled job in the same container
```sh
nelly app add scraper --name digest --git URL --ref main \
    --schedule "0 8 * * *" --entrypoint digest.py
nelly deploy scraper
# Each app gets its own venv — dependency conflicts can't propagate.
```

### Audit what's running
```sh
nelly list                                 # tabular view of all deployments
nelly list --json | jq '.[] | select(.state != "running")'
nelly ps
nelly stats
nelly inspect scraper
```

### Deploy from cron / CI
`nelly deploy` is non-interactive and exits non-zero on failure:
```cron
*/15 * * * * /home/me/nelly/bin/nelly deploy scraper >> /var/log/nelly-deploy.log 2>&1
```

---

## Configuration reference

`containers/<name>/def/config.json`:

```jsonc
{
  // Container + image names. container_name is docker-safe; image_name lowercase.
  "container_name": "scraper",
  "image_name":     "scraper",
  "restart":        "unless-stopped",
  "log_retention_days": 7,

  "apps": [
    {
      "app_name":   "fetcher",
      "source":     { "type": "git", "url": "git@github.com:me/scraper.git", "ref": "v1.4.0" },
      "schedule":   "*/5 * * * *",
      "entrypoint": "run.py"
    },
    {
      "app_name":   "dev",
      "source":     { "type": "local", "path": "/home/me/dev/scraper" },
      "schedule":   "*/2 * * * *",
      "entrypoint": "main.py"
    }
  ],

  // docker run --cpus / --memory / --memory-swap / --pids-limit
  "resources": {
    "cpus":         "1.0",
    "memory":       "512m",
    "memory_swap":  "1g",
    "pids_limit":   256
  },

  // docker --health-cmd / --health-interval / --health-timeout / --health-retries
  // Default cmd is "cron is running" when .cmd is empty.
  "health": {
    "cmd":      "",
    "interval": "30s",
    "timeout":  "5s",
    "retries":  3
  },

  "network": {
    "network_name": "nelly_net",
    "subnet":   "192.168.20.0/24",
    "gateway":  "192.168.20.1",
    "static_ip":"192.168.20.100",
    "ports":    ["8080:80"]
  },

  // Extra host:container bind mounts (the cron-logs mount is automatic).
  "volumes": [],

  // Extra Debian packages installed at image build time. Names are validated.
  "packages": ["git", "libpq-dev", "gcc"]
}
```

The legacy `git_url`+`ref`/`branch` per-app form is still accepted and
normalised to `{type:"git", …}` internally.

---

## Architecture

```
bin/nelly                arg parsing + dispatch (the only entry point users touch)
lib/
  common.sh              logging, locking, jq helpers, names, json output mode
  wizard.sh              interactive prompts + init/add-app/add-secrets wizards
  config.sh              validate / show / get / set / edit / add-app / remove-app
  app.sh                 `nelly app …` dispatcher (uses wizard or flags)
  source.sh              fetch_source() — git or local; returns resolved rev
  fetch.sh               iterates apps[], delegates to source.sh, updates lockfile
  build.sh               renders Dockerfile + crontab, tags w/ lockfile hash
  run.sh                 docker run (argv array, no eval), resources, healthcheck
  manage.sh              start/stop/restart/exec/shell/run-now/inspect
  stats.sh               ps + stats over nelly-managed containers
  list.sh                every deployment + state
  status.sh              one deployment's state + pinned commits
  logs.sh                tail per-app cron logs
  diff.sh                preview what fetch would change (git ls-remote)
  rollback.sh            switch to a previous image tag
  secrets.sh             manage .env with mode 0600 + key validation
  push.sh                docker cp into a running container
  explain.sh             plain-English summary
  doctor.sh              pre-flight checks
  prune.sh               delete old logs
containers/
  template/              what `nelly init` copies; default config + Dockerfile
  <name>/                a real deployment (gitignored)
tests/
  smoke.sh               offline checks: 30+ assertions; runs without Docker
```

**Why bash?** This is glue around `docker`, `git`, and `jq`. Bash keeps the glue
obvious. Every script can be run standalone for debugging
(`bash -x lib/build.sh /path/to/deploy`).

**Why no daemon?** Nelly's "service" is the Docker container it produces; the
CLI is stateless. Persistent state lives in the deployment directory on disk
and is versionable independently.

---

## Troubleshooting

**`config validation failed: …`**
`nelly validate <name>` prints the full list. Covers JSON syntax,
container/image name rules, app schemas, cron expressions, port mappings,
memory/cpu values, package names.

**Setup wizard prompts I don't want**
`nelly -y init <name>` accepts every default and adds no apps; you can
`nelly app add …` and `nelly secrets set …` later, or just `nelly edit <name>`.

**Pre-flight checks I want to skip**
`nelly doctor` is opt-in — it isn't a blocker for `nelly deploy`. The
config validator runs inside every deploy regardless, so unsafe configs
still get rejected.

**`flock: another nelly run is in progress`**
Another deploy/fetch/build/run holds the lock. Wait (Nelly will block
automatically) or kill the stale process. Locks live at `containers/<name>/.nelly.lock`.

**App ran in cron but I see no output**
Per-app output: `containers/<name>/logs/cron/<app>.log`. Tail with
`nelly logs <name> <app>`. If empty, `nelly shell <name>` and check
`/var/log/cron.log` inside the container — typical causes are a missing
entrypoint path or a bad shebang.

**`pip install` fails during build**
`nelly build <name> --dry-run` prints the rendered Dockerfile. Most failures
are missing OS deps — add them to `.packages[]` (e.g. `libpq-dev` for
`psycopg2`, `gcc` for C extensions).

**Container restarting in a loop**
`nelly inspect <name>` shows the health state. Then:
- `nelly logs <name>` for cron output,
- `docker logs <container>` for image-level output,
- `nelly shell <name>` to look around.

**I broke config.json by hand-editing**
`nelly validate <name>` will tell you what's wrong. `nelly edit` validates
on save and restores the previous version automatically if your edit is
invalid — prefer it for raw edits.

**Need to undo a bad release**
`nelly rollback <name>` (or `--to <tag>`). Previous images stay on disk;
only the running container is replaced.

---

## Development

```sh
bash tests/smoke.sh              # offline tests; no Docker required
shellcheck bin/nelly lib/*.sh    # optional but encouraged
```

The smoke suite covers: bash syntax, intro/help rendering, init → validate,
the full `nelly app …` subcommand surface, secrets file mode + round-trip,
invalid-config rejection (atomic — bad changes are rolled back), `explain`,
`doctor`, and `--json` output.

The library scripts are designed so each one is invokable standalone
(`bash lib/<x>.sh args…`), which makes debugging much cleaner than bisecting
through the dispatcher.

PRs welcome.

---

## License

MIT.
