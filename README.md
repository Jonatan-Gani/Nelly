# Nelly

**Deploy scheduled Python jobs the way you'd want to: one CLI, reproducible
builds, isolated dependencies, rollback in one command.**

You point Nelly at a Git repo *or a local directory*, give it a cron schedule
and an entrypoint, and Nelly produces a Docker container that runs it on
schedule — with per-app virtualenvs, runtime-mounted secrets, pinned commits,
healthchecks, resource limits, and persistent logs.

```
  source(s)              schedule + entrypoint              container
┌───────────┐           ┌──────────────────────┐           ┌─────────────┐
│ git repo  │           │  apps[].schedule     │           │  cron -f    │
│ or local  │──fetch──▶ │  apps[].entrypoint   │──build──▶ │  /opt/venvs │
│ directory │           │  apps[].source       │           │  per-app    │
└───────────┘           └──────────────────────┘           └─────────────┘
```

---

## Contents

1. [Install](#install)
2. [Five-minute tutorial](#five-minute-tutorial)
3. [Concepts](#concepts)
4. [Command reference](#command-reference)
5. [Recipes](#recipes)
6. [Configuration reference](#configuration-reference)
7. [Architecture](#architecture)
8. [Troubleshooting](#troubleshooting)
9. [Development](#development)

---

## Install

**Requirements** (host): Docker 20+, `bash`, `jq`, `git`, `rsync`. (Optional:
`flock` for concurrent-safety, `shellcheck` for development.)

```sh
git clone <this repo> ~/nelly
cd ~/nelly
# Optionally add to PATH so you can run `nelly …` from anywhere:
ln -s "$PWD/bin/nelly" ~/.local/bin/nelly
nelly --help
```

Nelly is a stateless wrapper around `docker` + `git`. All persistent state
lives under `containers/<deployment>/`.

---

## Five-minute tutorial

We'll deploy a small Python job from a GitHub repo on a 5-minute schedule.

```sh
# 1. Scaffold a deployment. Creates containers/scraper/ from the template.
nelly init scraper

# 2. Add an app that runs every 5 minutes.
nelly add-app scraper \
    --name fetcher \
    --git git@github.com:me/scraper.git --ref v1.4.0 \
    --schedule "*/5 * * * *" \
    --entrypoint run.py

# 3. Put secrets into the deployment's .env (mode 0600; never copied into the image).
nelly secrets set scraper DB_HOST=db.internal DB_PASS='hunter2'

# 4. Build & start the container. Unattended by default.
nelly deploy scraper

# 5. See it run.
nelly status scraper
nelly logs   scraper            # tail every app's cron output
nelly stats                     # live cpu / memory / pids
```

That's the whole loop. Read the rest of the README to see how to update,
roll back, run locally instead of from git, push hot-fixes, allocate
resources, and what happens under the hood.

---

## Concepts

### Deployments
A **deployment** is one directory under `containers/`. It holds a config, the
fetched source for each app, the `.env` with secrets, build artefacts, and
logs. One deployment ⇒ one Docker container.

```
containers/scraper/
├── def/
│   ├── config.json            # source of truth — apps, schedules, resources
│   ├── .env                   # secrets (mode 0600, mounted via --env-file)
│   ├── Dockerfile             # template; Nelly renders it at build time
│   ├── commits.lock.json      # which SHA each app was fetched at
│   ├── build_history.json     # recent builds (used by `rollback --list`)
│   └── last_image.txt         # image tag currently in service
├── apps/<app>/                # fetched source per app
└── logs/
    ├── cron/<app>.log         # per-app cron output (bind-mounted, persistent)
    ├── fetch.log build.log run.log
```

### Apps
Each entry under `apps[]` is one scheduled job. It declares:
- a name,
- a **source** (git URL+ref, or a local path),
- a **schedule** (5-field cron, or `@daily`/etc.),
- an **entrypoint** (path inside the repo, run with the app's own Python).

Apps inside the same container share the OS image but get **isolated venvs**
under `/opt/venvs/<app>`. They cannot break each other's dependencies.

### Sources
Two source types are supported:

```jsonc
// pinned to a git ref (branch, tag, or commit SHA)
"source": { "type": "git", "url": "git@github.com:me/scraper.git", "ref": "v1.4.0" }

// a directory on the host — re-synced on every fetch (great for local development)
"source": { "type": "local", "path": "/home/me/dev/scraper" }
```

Both types are recorded in `commits.lock.json` so every build is reproducible.
For local sources, the lockfile records the underlying git SHA when the
directory is a git working copy, or a content hash otherwise.

### Secrets
`def/.env` is mounted into the container via `--env-file` at runtime. **It is
never copied into the image.** Manage it via `nelly secrets …` so the file
mode stays at 0600 and your values survive round-tripping through quoting.

### Reproducibility
- `nelly fetch` resolves every app's revision and writes it to
  `commits.lock.json`.
- `nelly build` tags the image with `<image>:<short-lockfile-hash>` *and*
  `<image>:<timestamp>` *and* `<image>:latest`, so rolling back is just
  pointing at an old tag.
- `nelly rollback <name>` flips back to the previous build; `--to <tag>`
  jumps to any specific build; `--list` shows what's available.

### Locking
Every state-changing command takes a per-deployment `flock`. If two
`nelly deploy`s race, the second one waits for the first to finish instead
of trampling the build context.

---

## Command reference

`nelly --help` is authoritative; this table summarises.

### Setup & config
| Command                                              | What it does                              |
| ---------------------------------------------------- | ----------------------------------------- |
| `nelly init <name>`                                  | Scaffold `containers/<name>/`             |
| `nelly validate <name>`                              | Lint config (jq schema + cron + names)    |
| `nelly show <name>`                                  | Print current config                      |
| `nelly get <name> <jq-path>`                         | Read a config value (e.g. `.image_name`)  |
| `nelly set <name> <jq-path> <value>`                 | Write a config value (JSON-typed if it parses) |
| `nelly edit <name>`                                  | Open config.json in $EDITOR (validates on save) |

### App management
| Command                                              | What it does                              |
| ---------------------------------------------------- | ----------------------------------------- |
| `nelly add-app <name> --name N --git URL [--ref R] --schedule "* * * * *" --entrypoint FILE` | Add a new app |
| `nelly add-app <name> --name N --local PATH --schedule … --entrypoint …` | Same, from a local directory |
| `nelly remove-app <name> <app>`                      | Drop an app                               |
| `nelly set-schedule <name> <app> "<cron>"`           | Change one app's schedule                 |

### Secrets
| Command                                              | What it does                              |
| ---------------------------------------------------- | ----------------------------------------- |
| `nelly secrets set <name> KEY=value [...]`           | Write/replace one or more keys            |
| `nelly secrets unset <name> KEY [...]`               | Remove keys                               |
| `nelly secrets list <name>`                          | Print keys only (never values)            |
| `nelly secrets edit <name>`                          | Edit `.env` in $EDITOR; validates format  |
| `nelly secrets template <name>`                      | Print a `.env` skeleton from config       |

### Build / run
| Command                                              | What it does                              |
| ---------------------------------------------------- | ----------------------------------------- |
| `nelly fetch <name>`                                 | Refresh sources, update lockfile          |
| `nelly build <name>` / `… --dry-run`                 | Build the image (or just render the Dockerfile) |
| `nelly run <name>`                                   | (Re)start the container                   |
| `nelly deploy <name>`                                | fetch → build → run → prune (one shot)    |
| `nelly diff <name>`                                  | Show which apps would change on next fetch |
| `nelly rollback <name>` / `… --to TAG` / `… --list`  | Switch to a previous build                |
| `nelly push <name> <app> <src> [dst]`                | `docker cp` a file into a running app (hot, ephemeral) |

### Lifecycle
| Command                                              | What it does                              |
| ---------------------------------------------------- | ----------------------------------------- |
| `nelly start <name>` / `stop` / `restart`            | Container lifecycle                       |
| `nelly exec <name> -- <cmd...>`                      | Run a command inside the container        |
| `nelly shell <name>`                                 | Drop into a shell inside the container    |
| `nelly run-now <name> <app>`                         | Trigger one execution of an app immediately |
| `nelly inspect <name>`                               | Show resource limits, image, health, …    |

### Observation
| Command                                              | What it does                              |
| ---------------------------------------------------- | ----------------------------------------- |
| `nelly list` (alias `ls`)                            | All deployments + state                   |
| `nelly ps`                                           | docker ps over nelly-managed containers   |
| `nelly stats`                                        | Live cpu / memory / pids                  |
| `nelly status <name>`                                | One deployment's status + pinned commits  |
| `nelly logs <name> [app]`                            | Tail cron logs (all apps, or one)         |
| `nelly prune <name>`                                 | Delete old log files (`log_retention_days`) |

### Global flags
- `--json` — machine-readable output where supported (`list`, `ps`, `stats`,
  `status`, `inspect`, `rollback --list`, `secrets list`, `diff`).
- `-i, --interactive` — prompt before destructive ops (default is non-interactive).
- `-y, --yes` — explicit non-interactive (default behaviour, kept for clarity).
- `EDITOR=$EDITOR` — used by `edit` and `secrets edit`.

---

## Recipes

### Update an app to a new release
```sh
# A. Pin to a new ref in config.json and redeploy.
nelly set scraper '.apps[0].source.ref' 'v1.5.0'
nelly diff   scraper        # preview what'll change
nelly deploy scraper

# B. Or change the schedule only (no rebuild needed; redeploy regenerates crontab).
nelly set-schedule scraper fetcher "*/2 * * * *"
nelly deploy scraper
```

### Roll back to the previous build
```sh
nelly rollback scraper --list           # see recent builds
nelly rollback scraper                  # roll back one build
nelly rollback scraper --to scraper:abc123def4   # jump to a specific image
```

### Develop against a local directory (no git push needed)
```sh
nelly add-app scraper \
    --name dev \
    --local /home/me/dev/scraper \
    --schedule "*/2 * * * *" \
    --entrypoint main.py
nelly deploy scraper      # local dir is rsynced into apps/dev/
```

`nelly fetch` will always re-sync a `local` source, so iterating is just
`nelly deploy` (or `nelly push` for hot-iteration without a rebuild).

### Hot-patch a script without rebuilding
```sh
nelly push scraper fetcher ./run.py
nelly run-now scraper fetcher          # execute immediately
# The change is ephemeral — bake it in by editing the source and re-deploying.
```

### Cap resources
```sh
nelly set scraper '.resources.cpus' '0.5'
nelly set scraper '.resources.memory' '256m'
nelly set scraper '.resources.pids_limit' '128'
nelly deploy scraper
```

### Add a one-off OS package
```sh
nelly set scraper '.packages' '["git","libpq-dev","gcc","curl"]'
nelly deploy scraper
```

### Stand up multiple apps in one container
```sh
nelly add-app scraper --name fetcher --git URL --ref main --schedule "*/5 * * * *" --entrypoint fetch.py
nelly add-app scraper --name digest  --git URL --ref main --schedule "0 8 * * *"   --entrypoint digest.py
nelly deploy scraper
# Both get their own venv; one breaking deps cannot affect the other.
```

### Audit what's running
```sh
nelly list
nelly ps
nelly stats
nelly status scraper
nelly inspect scraper
nelly logs scraper fetcher
nelly list --json | jq '.[] | select(.state != "running")'
```

### Deploy from cron / CI
`nelly deploy` is non-interactive by default and exits non-zero on any
failure — drop it in cron or a CI job without ceremony:
```cron
*/15 * * * * /home/me/nelly/bin/nelly deploy scraper >> /var/log/nelly-deploy.log 2>&1
```

---

## Configuration reference

`containers/<name>/def/config.json`:

```jsonc
{
  // Container + image names (lowercase for image_name; docker-safe for container_name).
  "container_name": "scraper",
  "image_name":     "scraper",
  "restart":        "unless-stopped",     // docker --restart
  "log_retention_days": 7,                 // used by `nelly prune`

  "apps": [
    {
      "app_name":   "fetcher",
      "source":     { "type": "git", "url": "git@github.com:me/scraper.git", "ref": "v1.4.0" },
      "schedule":   "*/5 * * * *",         // 5-field cron, or @daily/@hourly/...
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
  // Defaults to "cron is running" if .cmd is empty.
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
    "ports":    ["8080:80"]                 // each entry validated against HOST[:CONTAINER][/proto]
  },

  // Extra host:container bind mounts beyond the default cron-logs mount.
  "volumes": [],

  // Extra Debian packages installed at image build time. Names validated.
  "packages": ["git", "libpq-dev", "gcc"]
}
```

### Backward compatibility
The legacy `git_url` + `ref`/`branch` form is still accepted:

```jsonc
{ "app_name": "x", "git_url": "git@github.com:me/x.git", "ref": "main", ... }
```

Internally, it's normalised to `{type:"git", ...}` by `lib/source.sh`.

---

## Architecture

```
bin/
  nelly                  single entry point; arg parsing + dispatch
lib/
  common.sh              logging, locking, jq helpers, names, output mode
  config.sh              jq-backed validation + edit/set/get/add-app/...
  source.sh              fetch_source() — git or local, returns resolved rev
  fetch.sh               iterates apps[], delegates to source.sh, updates lockfile
  build.sh               renders Dockerfile + crontab, tags image w/ lockfile hash
  run.sh                 docker run (argv array, no eval) w/ resources + health
  manage.sh              start/stop/restart/exec/shell/run-now/inspect
  stats.sh               ps + stats over nelly-managed containers
  rollback.sh            switch back to a previous image tag
  diff.sh                preview what fetch would change (git ls-remote)
  secrets.sh             manage .env with mode 0600 + key validation
  push.sh                docker cp into a running container
  list.sh                list every deployment and its state
  status.sh              one deployment's container + pinned commits
  logs.sh                tail per-app cron logs
  prune.sh               delete old logs
containers/
  template/              what `nelly init` copies; default config + Dockerfile
  <name>/                a real deployment (gitignored)
tests/
  smoke.sh               offline checks: syntax + config round-trips
```

**Why bash?** This is glue around `docker`, `git`, and `jq`. Bash makes that
glue obvious and inspectable. Every script also works as a standalone
subcommand for debugging (`bash -x lib/build.sh /path/to/deploy`).

**Why no daemon?** Nelly's "service" is the Docker container it produces;
the CLI is stateless. Persistent state lives in the deployment directory
on disk (versioned independently if you want).

---

## Troubleshooting

**`config validation failed: …`**
Run `nelly validate <name>` to see the full list. The validator covers JSON
syntax, container/image name rules, app schemas, cron expressions, port
mappings, memory/cpu values, and package names.

**`flock: another nelly run is in progress`**
Another `nelly deploy`/`fetch`/`build`/`run` is currently holding the
deployment's lock. Wait for it (Nelly will block automatically) or `kill`
the stale process. Locks live at `containers/<name>/.nelly.lock`.

**App ran in cron but I see no output**
Per-app output goes to `containers/<name>/logs/cron/<app>.log`. Tail it with
`nelly logs <name> <app>`. If the file is empty, exec into the container
(`nelly shell <name>`) and check `/var/log/cron.log`; common causes are a
missing `entrypoint` path or a bad shebang in the Python script.

**`pip install` fails during build**
Inspect the rendered Dockerfile with `nelly build <name> --dry-run`. Most
failures are missing system deps — add them to `.packages[]` (e.g.
`libpq-dev` for `psycopg2`, `gcc` for anything with C extensions).

**Container restarting in a loop**
`nelly inspect <name>` shows the health state. Then:
- `nelly logs <name>` for cron output,
- `docker logs <container>` for image-level output,
- `nelly shell <name>` to look around.

**Need to undo a bad release**
`nelly rollback <name>` (or `--to <tag>`). The previous image is still on
disk; only the running container is replaced.

**`secrets list` shows fewer keys than I expected**
The `.env` file is only parsed line-by-line. Multi-line values aren't
supported — keep secrets to one line each.

---

## Development

```sh
bash tests/smoke.sh         # offline tests — no Docker needed
shellcheck bin/nelly lib/*.sh   # optional but encouraged
```

Smoke tests cover bash syntax, CLI help, init → validate → set/get round-trips,
add-app/remove-app/set-schedule, secrets file mode + round-trip, invalid-config
rejection, and `--json` output.

PRs welcome. The library scripts are designed so that each one can be exercised
standalone (`bash lib/<x>.sh …`), which makes debugging much easier than
bisecting through the dispatcher.

---

## License

MIT.
