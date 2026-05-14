# Nelly

**Schedule Python jobs in Docker, painlessly.** Production-grade,
single-CLI, no daemon.

Give Nelly a Python source (git repo *or* a local directory), a cron
schedule, and an entrypoint. It produces a Docker container that runs
your script on that schedule — with isolated dependencies, runtime-mounted
secrets, pinned commits, healthchecks, resource limits, persistent logs,
hooks, multi-network attachment, declarative export/import, backup/restore,
and a deploy pipeline you can trust.

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

**1. Guided CLI** — `nelly init` walks you through setup, `nelly app add`
   is interactive when you don't pass flags, `nelly explain`/`nelly doctor`
   show you what you've got and what to fix, `nelly plan` previews
   exactly what `nelly deploy` will do.

**2. Edit config.json directly** — the file under `containers/<name>/def/config.json`
   is the source of truth. `nelly edit` opens it in your editor and
   validates on save. Every other command is convenience.

**3. Import a config someone else wrote** — `nelly init <name> --from prod.json`
   or `nelly import prod.json --as prod` materialises a deployment from
   a JSON export. Useful for CI, fleet management, or moving to a new host.

---

## Contents

1. [Install](#install)
2. [Five-minute tutorial](#five-minute-tutorial)
3. [Loading a deployment from a file](#loading-a-deployment-from-a-file)
4. [Editing config.json directly](#editing-configjson-directly)
5. [Concepts](#concepts)
6. [Command map](#command-map)
7. [Recipes](#recipes)
8. [Configuration reference](#configuration-reference)
9. [Architecture](#architecture)
10. [Troubleshooting](#troubleshooting)
11. [Development](#development)

---

## Install

Host requirements: Docker 20+, `bash`, `jq`, `git`, `rsync`. Optional:
`flock` (concurrency-safe locks), `shellcheck` (development),
`python3` (cron next-run preview).

```sh
git clone <this-repo> ~/nelly
cd ~/nelly
ln -s "$PWD/bin/nelly" ~/.local/bin/nelly   # optional — puts `nelly` on $PATH
nelly --version
nelly                                       # short intro + happy-path commands
```

Nelly is a stateless wrapper around `docker` + `git` + `jq`. All persistent
state lives under `containers/<deployment>/`.

---

## Five-minute tutorial

```sh
# 1. Scaffold a deployment. Walks you through 5 questions, with defaults.
nelly init scraper

# 2. Preview what's configured. Plain English.
nelly explain scraper

# 3. Pre-flight checks: config valid? git reachable? docker running?
nelly doctor scraper

# 4. See exactly what `nelly deploy` will do — no side effects.
nelly plan scraper

# 5. Build the image and start the container. Wait for healthcheck, auto-rollback on failure.
nelly deploy scraper --wait-healthy 60 --auto-rollback

# 6. See it run.
nelly status scraper
nelly cron   scraper          # what's scheduled, when does each app next run?
nelly logs   scraper          # tail every app's cron output
nelly stats                   # live cpu / memory / pids

# 7. Drop into the app's venv inside the container.
nelly shell scraper --app fetcher    # cwd=/home/apps/fetcher, $PATH points at the app's venv
```

### What `nelly init` asks you

```
Container name?       [scraper]
Image name?           [scraper]
Add an app now?       [Y/n]
  App name?           fetcher
  Where does the code come from?
    1) Git repository (clone at a ref)
    2) Local directory (rsync from a path on this host)
  Git URL?            git@github.com:me/scraper.git
  Branch / tag / commit SHA?  [main]   v1.4.0
  Cron schedule?      [*/5 * * * *]
  Entry point?        [main.py]        run.py
  About to add this app: {...preview...}
  Looks good?         [Y/n]
Add secrets now?      [y/N] y
  Key name?           DB_HOST
  Value (hidden)?
  ...
```

`nelly -y init scraper` skips every prompt — just scaffolds. Pair with
`nelly app add` / `nelly secrets set` / `nelly edit` afterwards.

---

## Loading a deployment from a file

Treat deployments like infrastructure-as-code:

```sh
# On host A: export the deployment (no secrets by default — safe to commit)
nelly export scraper > scraper.json
git add scraper.json && git commit -m "scraper deployment"

# On host B: materialise the same deployment
git pull
nelly init scraper --from scraper.json -y
nelly secrets set scraper DB_PASS=...        # secrets stay per-host
nelly deploy scraper
```

Want to fork an existing deployment?

```sh
nelly clone scraper scraper-staging          # config copy; secrets NOT copied
nelly edit  scraper-staging                  # tweak per-env settings
nelly deploy scraper-staging
```

Need to migrate to a new host?

```sh
# On the old host:
nelly backup scraper --out scraper.tar.gz    # config + secrets + lockfile + history
scp scraper.tar.gz new-host:

# On the new host:
nelly restore scraper.tar.gz
nelly deploy scraper
```

---

## Editing config.json directly

```sh
nelly edit scraper                  # opens $EDITOR; validates on save
nelly doctor scraper                # sanity-check
nelly plan scraper                  # preview the changes
nelly deploy scraper                # apply
```

Any external editor (`vim def/config.json`, IDE, etc.) works too. Every
Nelly command that reads the config validates it, so a broken edit is
rejected with a clear error before it can hurt you.

---

## Concepts

### Deployments
A **deployment** is one directory under `containers/`. It holds a config, the
fetched source for each app, the secrets, build artefacts, and logs. One
deployment ⇒ one Docker container.

```
containers/scraper/
├── def/
│   ├── config.json            # source of truth — apps, schedules, resources, hooks…
│   ├── .env                   # secrets (mode 0600, mounted via --env-file)
│   ├── Dockerfile             # template; Nelly renders it at build time
│   ├── hooks/                 # optional pre_deploy / post_deploy / on_failure scripts
│   ├── commits.lock.json      # which revision each app was fetched at
│   ├── build_history.json     # recent builds (rollback uses this)
│   └── last_image.txt         # image currently in service
├── apps/<app>/                # fetched source per app
└── logs/
    ├── cron/<app>.log         # per-app cron output (bind-mounted)
    ├── fetch.log build.log run.log
```

### Apps
Each entry under `apps[]` is one scheduled job: name, source (git or local),
schedule (cron), entrypoint. Apps in the same container share the OS image
but get **isolated virtualenvs** under `/opt/venvs/<app>` so dependency
conflicts can't propagate.

### Sources
Two source types are first-class:

```jsonc
// pinned git
"source": { "type": "git", "url": "git@github.com:me/scraper.git", "ref": "v1.4.0" }

// local directory — rsynced on every fetch (great for development)
"source": { "type": "local", "path": "/home/me/dev/scraper" }
```

Both are recorded in `commits.lock.json` so every build is reproducible.

### Secrets
`def/.env` is mounted via `--env-file` at runtime — **never copied into the
image**. Manage it through `nelly secrets …` so the file stays at mode 0600.

### Reproducibility
Every build is tagged with `<image>:<lockfile-hash>` AND `<image>:<timestamp>`
AND `<image>:latest`. `nelly rollback` swaps tags. The lockfile pins exact
revisions, so exporting + importing on another host produces the same image.

### Tags
Add free-form tags to deployments (`prod`, `critical`, `team-a`). Use
`nelly tag` to manage them. `nelly all --tag prod deploy` operates on
groups.

### Hooks
`config.hooks.{pre_deploy,post_deploy,on_failure}` point at shell scripts
that run on the host around each deploy. Useful for DB migrations, Slack
notifications, cache warm-ups, etc. See
`containers/template/def/hooks/example.sh.disabled` for a working
template.

### Locking
Every state-changing command takes a per-deployment `flock`. Concurrent
deploys queue cleanly instead of trampling each other.

### Atomic config edits
`nelly set` and `nelly app add` snapshot the config, write, validate, and
restore the snapshot on failure. A rejected value never leaves the config
half-broken.

---

## Command map

`nelly help` is authoritative. Quick overview by topic.

### Get started
- `nelly init <name>` — interactive wizard
- `nelly init <name> --from <file>` — from an export
- `nelly explain <name>` — plain-English summary
- `nelly doctor <name>` — pre-flight checks
- `nelly plan <name>` — preview `deploy` with no side effects

### Deploy / update
- `nelly deploy <name>` — fetch → build → run → prune
- `nelly deploy <name> --wait-healthy 60 --auto-rollback` — wait for health, roll back on failure
- `nelly fetch / build [--dry-run] / run` — individual steps
- `nelly rollback <name> [--to TAG | --list]`
- `nelly diff <name>` — what would change on next fetch
- `nelly push <name> <app> <src> [dst]` — hot-copy a file into a running app

### Manage apps
- `nelly app add/list/show/remove/schedule/ref/path <name> …`

### Manage config / secrets
- `nelly edit / show / get / set / validate <name>`
- `nelly tag <name> add|remove|list TAG…`
- `nelly secrets set/unset/list/edit/template <name> …`

### Lifecycle
- `nelly start / stop / restart <name>`
- `nelly exec <name> -- <cmd…>`
- `nelly shell <name> [--app <app>]` — `--app` puts you in that app's venv
- `nelly attach <name>` — stream container stdout
- `nelly run-now <name> <app>` — execute immediately
- `nelly top <name>` — processes inside the container
- `nelly inspect <name>` — resources, image, health, networks

### Observe
- `nelly list` (alias `ls`) — all deployments, with state and image
- `nelly ps` — docker ps over nelly-managed containers
- `nelly stats` — live cpu / memory / pids
- `nelly status <name>` — one deployment + pinned commits
- `nelly logs <name> [app]` — tail container logs
- `nelly events <name> [--since DUR]` — docker events stream
- `nelly cron <name> [--next N]` — what's scheduled, in English
- `nelly prune <name>` — delete old log files

### Share / migrate / back up
- `nelly export <name>` (`--include-secrets`, `--include-lockfile`)
- `nelly import <file|-> [--as <name>] [--force]`
- `nelly clone <src> <dest>`
- `nelly backup <name> [--out PATH] [--include-logs]`
- `nelly restore <tarball> [--as <name>] [--force]`

### Across many deployments
- `nelly all list [--tag T]…`
- `nelly all <cmd> [--tag T]… [--fail-fast]`

### Global flags
- `--json` — machine-readable output where supported
- `-i, --interactive` — prompt before destructive ops
- `-y, --yes` — never prompt
- `--version`

---

## Recipes

### Production deploy with safety
```sh
nelly deploy scraper --wait-healthy 60 --auto-rollback
# fetches, builds, runs, waits up to 60s for health to pass,
# rolls back to the previous image automatically if it doesn't.
```

### Pin to a release and roll it forward
```sh
nelly app ref scraper fetcher v1.5.0
nelly plan   scraper             # preview
nelly deploy scraper --wait-healthy 60 --auto-rollback
```

### Get into a running app's shell
```sh
nelly shell scraper --app fetcher
# inside the container:
#   $ python --version    # the app's venv python
#   $ python run.py       # one-off invocation
```

### See what's scheduled and when
```sh
nelly cron scraper                # human descriptions
nelly cron scraper --next 3       # also the next 3 run times per app
```

### Multi-deployment ops
```sh
nelly tag scraper add prod
nelly tag digest  add prod
nelly all list --tag prod
nelly all deploy --tag prod --fail-fast --wait-healthy 60 --auto-rollback
nelly all restart --tag prod
```

### Migrate a deployment to a new host
```sh
# old host
nelly backup scraper --out scraper.tar.gz
scp scraper.tar.gz newhost:

# new host
nelly restore scraper.tar.gz
nelly doctor scraper
nelly deploy scraper
```

### Version-control your deployments
```sh
nelly export scraper > deployments/scraper.json
git add deployments/scraper.json && git commit -m "scraper config"
# elsewhere
nelly import deployments/scraper.json --as scraper
```

### Develop against a local directory
```sh
nelly app add scraper --name dev --local /home/me/dev/scraper \
                      --schedule "*/2 * * * *" --entrypoint main.py
nelly deploy scraper        # local dir is rsynced into apps/dev/
nelly push   scraper dev ./run.py     # hot-patch a single file
nelly run-now scraper dev             # execute immediately
```

### Production wiring: Traefik labels + DNS aliases
```sh
nelly set scraper '.network.labels' '{"traefik.enable":"true","traefik.http.routers.scraper.rule":"Host(`scraper.example.com`)"}'
nelly set scraper '.network.aliases' '["scraper.internal","fetcher.internal"]'
nelly set scraper '.network.extra_networks' '["traefik_proxy"]'
nelly deploy scraper
```

### Slack notifications on deploy
```sh
# 1. Drop a hook script
cat > containers/scraper/def/hooks/post-deploy.sh <<'SH'
#!/usr/bin/env bash
curl -fsS -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
     -d "{\"text\":\":rocket: $NELLY_DEPLOYMENT deployed as $NELLY_IMAGE\"}"
SH
chmod +x containers/scraper/def/hooks/post-deploy.sh

# 2. Point config at it
nelly set scraper '.hooks.post_deploy' '"./def/hooks/post-deploy.sh"'

# 3. SLACK_WEBHOOK should be in the host environment (NOT def/.env — hooks run on the host)
nelly deploy scraper
```

### CI: deploy on tag
```yaml
# .github/workflows/deploy.yml (sketch)
on: { push: { tags: ['v*'] } }
jobs:
  deploy:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      - run: nelly app ref scraper fetcher ${{ github.ref_name }}
      - run: nelly deploy scraper --wait-healthy 90 --auto-rollback
```

---

## Configuration reference

`containers/<name>/def/config.json`:

```jsonc
{
  "container_name": "scraper",
  "image_name":     "scraper",
  "restart":        "unless-stopped",
  "log_retention_days": 7,

  "tags": ["prod", "team-a"],

  "apps": [
    {
      "app_name":   "fetcher",
      "source":     { "type": "git", "url": "git@github.com:me/scraper.git", "ref": "v1.4.0" },
      "schedule":   "*/5 * * * *",
      "entrypoint": "run.py"
    }
  ],

  "resources": {
    "cpus":         "1.0",
    "memory":       "512m",
    "memory_swap":  "1g",
    "pids_limit":   256
  },

  "health": {
    "cmd":      "",          // empty → default ("cron is running")
    "interval": "30s",
    "timeout":  "5s",
    "retries":  3
  },

  "network": {
    "network_name":   "nelly_net",
    "subnet":         "192.168.20.0/24",
    "gateway":        "192.168.20.1",
    "static_ip":      "192.168.20.100",
    "hostname":       "scraper-1",
    "ports":          ["8080:80"],

    "extra_networks": ["traefik_proxy", "redis_net"],
    "aliases":        ["scraper.internal"],
    "dns":            ["1.1.1.1"],
    "extra_hosts":    ["db.internal:10.0.0.5"],
    "labels": {
      "traefik.enable": "true",
      "traefik.http.routers.scraper.rule": "Host(`scraper.example.com`)"
    }
  },

  "volumes": ["/srv/scraper-data:/data"],

  "hooks": {
    "pre_deploy":  "./def/hooks/pre.sh",
    "post_deploy": "./def/hooks/post.sh",
    "on_failure":  "./def/hooks/fail.sh"
  },

  "packages": ["git", "libpq-dev", "gcc"]
}
```

The legacy `git_url`+`ref`/`branch` per-app form is still accepted and
normalised to `{type:"git", …}` internally.

### Hook environment

Hooks are shell scripts on the **host** that Nelly runs at lifecycle points:

| Hook          | When                                              | Failure means       |
| ------------- | ------------------------------------------------- | ------------------- |
| `pre_deploy`  | Before `fetch`                                    | Abort the deploy    |
| `post_deploy` | After a successful `run` (and health, if waited)  | Logged, not fatal   |
| `on_failure`  | If the deploy fails                               | Logged, not fatal   |

Each hook gets these env vars:

| Variable           | Value                                                       |
| ------------------ | ----------------------------------------------------------- |
| `NELLY_DEPLOYMENT` | Deployment name                                             |
| `NELLY_DEPLOY_DIR` | Absolute path to the deployment directory                   |
| `NELLY_HOOK`       | One of `pre_deploy` / `post_deploy` / `on_failure`          |
| `NELLY_IMAGE`      | Image tag that was just built (best-effort)                 |

---

## Architecture

```
bin/nelly                arg parsing + dispatch (the only entry point users touch)
lib/
  common.sh              logging, locking, jq helpers, names, output mode
  wizard.sh              interactive prompts + init/add-app/add-secrets wizards
  config.sh              validate / show / get / set / edit / add-app / tags
  app.sh                 `nelly app …` dispatcher (uses wizard or flags)
  source.sh              fetch_source() — git or local; returns resolved rev
  fetch.sh               iterate apps[], delegate to source.sh, update lockfile
  build.sh               render Dockerfile + crontab, tag image w/ lockfile hash
  run.sh                 docker run (argv array, no eval) — resources, health,
                         multi-network, aliases, labels, hostname, dns, hosts,
                         wait-healthy + auto-rollback
  manage.sh              start/stop/restart/exec/shell/attach/run-now/top/inspect
  stats.sh               ps + stats over nelly-managed containers
  list.sh                every deployment + state
  status.sh              one deployment's state + pinned commits
  logs.sh                tail per-app cron logs
  events.sh              stream docker events
  cron.sh                human-readable crontab + next-run preview
  diff.sh                preview what fetch would change
  plan.sh                preview the full deploy pipeline (no side effects)
  rollback.sh            switch to a previous image tag
  secrets.sh             manage .env with mode 0600 + key validation
  push.sh                docker cp into a running container
  explain.sh             plain-English summary
  doctor.sh              pre-flight checks
  hooks.sh               run pre_deploy / post_deploy / on_failure
  portable.sh            export / import / clone / init-from
  backup.sh              backup / restore tarball
  all.sh                 multi-deployment dispatcher with --tag filtering
  prune.sh               delete old logs
containers/
  template/              `nelly init` copies this; reference config + Dockerfile
  <name>/                a real deployment (gitignored)
tests/
  smoke.sh               offline checks: 50+ assertions; runs without Docker
```

**Why bash?** This is glue around `docker`, `git`, and `jq`. Bash keeps the
glue obvious. Every script can be run standalone for debugging
(`bash -x lib/build.sh /path/to/deploy`).

**Why no daemon?** Nelly's "service" is the Docker container it produces; the
CLI is stateless. Persistent state lives in the deployment directory on disk
and is versionable independently.

**Why version 0.x?** The format is still evolving — the export/import schema
is `nelly_export_version: 1` and Nelly refuses to load mismatched versions
rather than guess.

---

## Telegram bot (optional, secure remote monitoring)

If you want to check on your deployments from your phone — and optionally
trigger restarts/deploys/rollbacks from there — Nelly ships an optional
Telegram bot. It runs on the same host as Nelly, talks to Telegram via
long-polling (no public endpoint required), and is **locked to an
allow-list of Telegram user IDs**. Anyone not on the list is silently
dropped; the bot never confirms it exists to a wrong audience.

### Setup (one-time)

```sh
# 1. Talk to @BotFather on Telegram → /newbot → copy the token.

# 2. Run the setup wizard. It will:
#    - validate the token against the Telegram API
#    - ask you to message the bot once, then auto-detect your user id
#    - ask whether to enable write commands (start/stop/deploy/rollback)
#    - send a hello message to confirm wiring
nelly bot setup

# 3. (recommended) install a user systemd unit so the bot survives reboots:
nelly bot install-systemd
systemctl --user daemon-reload
systemctl --user enable --now nelly-bot
sudo loginctl enable-linger "$USER"     # keep running after logout

# Or just run it in the foreground:
nelly bot start
```

Add more allowed users later:
```sh
nelly bot allow  123456789
nelly bot revoke 987654321
nelly bot status                 # is it running? recent activity?
```

### Bot commands (from Telegram)

Read-only (always available):

| Command            | What it does                              |
| ------------------ | ----------------------------------------- |
| `/help`            | List available commands                   |
| `/list`            | All deployments + state                   |
| `/status <name>`   | One deployment's status                   |
| `/ps`              | docker ps over nelly-managed containers   |
| `/stats`           | live cpu / memory / pids                  |
| `/logs <name> [app]` | Last 30 lines of cron output            |
| `/cron <name>`     | What's scheduled, in plain English        |
| `/explain <name>`  | Deployment summary                        |
| `/doctor <name>`   | Pre-flight checks                         |
| `/events <name>`   | Recent docker events                      |
| `/id`              | Print your own Telegram user id           |

Write-capable (only when `allow_writes: true` in `bot/config.json`):

| Command                       | What it does                                       |
| ----------------------------- | -------------------------------------------------- |
| `/start_dep <name>`           | `docker start`                                     |
| `/stop_dep <name>`            | `docker stop`                                      |
| `/restart_dep <name>`         | `docker restart`                                   |
| `/runnow <name> <app>`        | Trigger one app run immediately                    |
| `/deploy <name>`              | Full deploy with `--wait-healthy 60 --auto-rollback` |
| `/rollback <name>`            | Switch to previous build                           |

Toggle writes any time:
```sh
nelly set-jq() { jq "$2 = $3" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
# (or just edit bot/config.json by hand — it's a one-liner)
```
The bot re-reads its config on every poll, so changes take effect without
a restart.

### Proactive notifications (recommended)

`nelly bot notify "<msg>"` sends a message to every allowed user (or to
`notify_chat_id` if set). It works whether or not the bot daemon is
running — it just hits the Telegram API directly. Wire it into your
deploy hooks for free push notifications:

```sh
# def/hooks/notify.sh  (chmod +x)
#!/usr/bin/env bash
case "$NELLY_HOOK" in
    post_deploy) /usr/local/bin/nelly bot notify "✅ $NELLY_DEPLOYMENT deployed as $NELLY_IMAGE" ;;
    on_failure)  /usr/local/bin/nelly bot notify "❌ $NELLY_DEPLOYMENT failed to deploy" ;;
esac
```

```sh
nelly set scraper '.hooks.post_deploy' '"./def/hooks/notify.sh"'
nelly set scraper '.hooks.on_failure'  '"./def/hooks/notify.sh"'
```

### Security model for the bot

| Concern               | Mitigation                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------ |
| Token leak            | Token lives at `bot/.token`, mode 0600, never echoed to logs. Replace and restart to rotate.     |
| Unknown senders       | Allow-list of numeric Telegram user IDs. Anything else is **silently dropped** (no reply).       |
| Command injection     | Every command maps to a fixed `nelly <subcommand>` invocation with `shell=False`. Arguments validated by regex (`[A-Za-z0-9_.-]+`). |
| Mutating actions      | Disabled by default. Need to flip `allow_writes: true` in `bot/config.json` to enable any write. |
| Token sprawl          | The CLI rejects tokens that don't match Telegram's format. systemd unit hardened with `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=full`, `ProtectHome=read-only`. |
| Rate / flood          | Per-user sliding window: 30 commands / 60 s. Excess gets a one-line "slow down" reply and a log entry. |
| Audit trail           | `bot/bot.log` (append-only) records every command attempt: who, what, when, outcome.             |
| Allowed-update types  | The bot subscribes only to `message` updates from Telegram; everything else is ignored.          |

The bot daemon **only invokes `nelly` subcommands** — it never executes
arbitrary shell, never builds command strings, and runs Python with the
stdlib only (no pip install, no transitive dependencies).

---

## Security model

Nelly's trust boundary is the **deployment config file**. Anything inside
`containers/<name>/def/config.json` is treated as code: it determines what
gets built into a Docker image, what host paths get mounted into it, what
runs at root inside cron, and what hooks run on the host. Treat config
imports (`nelly import`, `nelly restore`, `nelly init --from`) like any
other untrusted artifact — review them before deploying.

The validator (`nelly validate`) enforces these rules on every state-changing
command. They are the protections an untrusted config has to defeat:

- **App `entrypoint` is restricted to `[A-Za-z0-9_./-]+`**, with no `..`
  or leading `/`. This eliminates the cron-injection path: the assembled
  crontab invokes `python` directly with the entrypoint as an argv item —
  no shell wrapping, no quoting concerns.
- **Local source paths must be absolute, must not contain `..`**, and may
  not point at obvious system directories (`/`, `/etc`, `/root`, `/proc`,
  `/sys`, `/dev`, `/boot`, `/var/run/docker.sock`).
- **Volume host sides must be absolute, must not contain `..`**, and are
  subject to the same system-directory deny-list as local sources, plus
  `/var/lib/docker[/…]`.
- **Hook paths must be relative**, must not contain `..`, and must resolve
  (via `realpath -m`) to a file under the deployment directory. Hooks
  run on the host with the invoking user's privileges — they are not
  sandboxed.
- **Git URLs and refs must not begin with `-`**, closing the
  CVE-2017-1000117-class argument-injection vector. Every `git clone` /
  `ls-remote` / `checkout` invocation in Nelly also uses the `--`
  argument terminator as defense-in-depth.
- **Tags, image names, container names, package names** are all anchored
  to their respective POSIX-safe character classes.

If you genuinely need to escape one of the path deny-lists (e.g. a
read-only mount of `/etc/letsencrypt/live`), set the corresponding
opt-in **at the top level of the config**:

```jsonc
{
  "allow_dangerous_volumes": true,   // skips the volume deny-list
  "allow_dangerous_paths":   true,   // skips the local-source deny-list
  ...
}
```

This is an explicit, file-visible decision rather than a hidden flag.

### Threat model assumptions

- The host running `nelly` is trusted; the user running `nelly` is trusted.
- Configs you author yourself are trusted.
- **Configs imported from elsewhere are not trusted** — the validator,
  the entrypoint runtime check in `lib/manage.sh`, and the hook
  runtime check in `lib/hooks.sh` are designed to catch malicious imports
  before they execute anything on the host.
- The cron jobs *inside* the container run as root inside the container.
  Container escape is out of scope — that's docker's responsibility.
  What's in scope: making sure the *configuration* doesn't hand the
  container the keys to the host (via dangerous mounts, hostile git URLs,
  or hook scripts pointing at arbitrary host binaries).

### Reporting

Found something the validator misses? Please open an issue with the
shortest config that reproduces the bypass.

---

## Troubleshooting

**`config validation failed: …`**
`nelly validate <name>` prints every issue. Covers JSON syntax, container/image
name rules, app schemas, cron expressions, port mappings, memory/cpu values,
package names, tag names, and hook paths.

**Setup wizard prompts I don't want**
`nelly -y init <name>` skips every optional step. Use `nelly app add` and
`nelly secrets set` afterwards, or just `nelly edit`.

**Pre-flight checks I want to skip**
`nelly doctor` is opt-in — not a deploy blocker. The config validator runs
inside every deploy regardless, so unsafe configs still get rejected.

**`flock: another nelly run is in progress`**
Another deploy/fetch/build/run holds the lock. Wait (Nelly blocks
automatically) or kill the stale process. Locks live at
`containers/<name>/.nelly.lock`.

**Container restarting in a loop**
`nelly inspect <name>` shows the health state. Then:
- `nelly events <name>` for the lifecycle event stream,
- `nelly logs <name>` for cron output,
- `nelly shell <name>` to look around,
- `docker logs <container>` for image-level output.

**App ran in cron but I see no output**
Per-app output is at `containers/<name>/logs/cron/<app>.log`. Tail with
`nelly logs <name> <app>`. If empty, `nelly shell <name>` and check
`/var/log/cron.log` inside — typical causes are a missing entrypoint path
or a bad shebang in the Python script.

**Need to undo a bad release**
`nelly rollback <name>` (or `--to <tag>`). Previous images stay on disk;
only the running container is replaced. With `--auto-rollback` and
`--wait-healthy`, Nelly will roll back on its own when a deploy fails
health.

**Import refuses with "unsupported export version"**
Newer exports aren't readable by older versions of Nelly. Re-export from
the newer side, or upgrade Nelly on the importing side.

**Backup tarball doesn't include `apps/`**
That's by design — Nelly's `fetch` step recreates `apps/` from the source.
The lockfile inside the backup pins exact revisions. Pass
`--include-logs` if you also want to preserve old cron output.

**I edited config.json by hand and broke it**
`nelly edit` validates on save and rolls back if your edit is invalid —
prefer it for raw edits. If you've already saved a broken version, run
`nelly validate <name>` to see what's wrong.

---

## Development

```sh
bash tests/smoke.sh              # offline tests — no Docker required
shellcheck bin/nelly lib/*.sh    # optional but encouraged
```

The smoke suite (`tests/smoke.sh`) covers: bash syntax, intro/help/version
rendering, `init -y → validate`, the full `nelly app …` subcommand surface,
secrets file mode + round-trip, invalid-config rejection (atomic rollback),
`explain`, `doctor`, `cron`, `plan`, `tag` add/remove/list, `export → import`
round-trip, `clone`, `backup → restore` round-trip, `all --tag` filtering,
and `--json` output. ~50 assertions; runs in ~5 seconds.

Each library script is invokable standalone (`bash lib/<x>.sh args…`),
which makes debugging much cleaner than bisecting through the dispatcher.

PRs welcome.

---

## License

MIT.
