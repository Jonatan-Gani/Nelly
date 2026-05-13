# Nelly

Simplifies deploying scheduled Python scripts. You point Nelly at a Git repo, give it a cron schedule and an entrypoint, and Nelly builds a Docker image that runs it on a schedule — with isolated dependencies, runtime secrets, pinned commits, and persistent logs.

```
git repo + schedule + entrypoint  ──►  nelly deploy  ──►  scheduled container
```

## Quick start

```sh
# 1. Scaffold a new deployment.
bin/nelly init mybot

# 2. Edit the apps array in containers/mybot/def/config.json:
#      git_url, ref (commit/tag/branch), schedule, entrypoint, requirements.txt path
#    Drop secrets into containers/mybot/def/.env  (mounted at runtime, never baked).

# 3. Deploy.
bin/nelly deploy mybot

# 4. Watch it run.
bin/nelly logs   mybot
bin/nelly status mybot
```

## What `nelly deploy` does

1. **fetch**   — `git clone` each app at the configured ref, write the resolved commit SHA to `def/commits.lock.json` so the build is reproducible.
2. **build**   — generate a crontab from `apps[].schedule` + `apps[].entrypoint`, create per-app virtualenvs under `/opt/venvs/<app>`, install OS packages from `config.packages[]`, build the image and tag it with the lockfile hash.
3. **run**     — (re)start the container. Secrets come from `def/.env` via `--env-file`; cron logs are volume-mounted to `logs/cron/<app>.log` on the host.
4. **prune**   — delete log files older than `log_retention_days`.

Every step is non-interactive by default. Pass `-i` to be prompted before destructive actions (e.g. replacing a running container).

## Configuration

A single `def/config.json` per deployment:

```json
{
  "container_name": "mybot",
  "image_name": "mybot",
  "log_retention_days": 7,

  "apps": [
    {
      "app_name": "scraper",
      "git_url":  "git@github.com:me/scraper.git",
      "ref":      "v1.4.0",
      "schedule": "*/15 * * * *",
      "entrypoint": "run.py"
    },
    {
      "app_name": "digest",
      "git_url":  "git@github.com:me/digest.git",
      "ref":      "main",
      "schedule": "0 7 * * *",
      "entrypoint": "send_digest.py"
    }
  ],

  "network": {
    "network_name": "nelly_net",
    "subnet":  "192.168.20.0/24",
    "gateway": "192.168.20.1",
    "static_ip": "192.168.20.100",
    "ports": ["8080:80"]
  },

  "packages": ["git", "libpq-dev", "gcc"]
}
```

**App contract.** Each entry in `apps[]` needs `app_name`, `git_url`, `ref`, `schedule`, and `entrypoint`. If the repo has a `requirements.txt` at its root, it'll be installed into that app's isolated venv. Apps don't need to know anything about Nelly.

**Secrets.** Put them in `def/.env`. The file is mounted via `--env-file` at run time and is never copied into the image.

**Reproducibility.** `def/commits.lock.json` records the exact SHA each app was deployed at. Image tags include a hash of the lockfile, so rolling back is `docker run <image>:<old-tag>`.

## Commands

| Command                       | What it does                                              |
| ----------------------------- | --------------------------------------------------------- |
| `nelly init <name>`           | Scaffold `containers/<name>` from the template            |
| `nelly deploy <name>`         | Full pipeline: fetch → build → run → prune                |
| `nelly fetch  <name>`         | Refresh app repos, update lockfile                        |
| `nelly build  <name>`         | Rebuild the image from current `apps/` and config         |
| `nelly run    <name>`         | (Re)start the container                                   |
| `nelly logs   <name> [app]`   | Tail all cron logs (or one app's)                         |
| `nelly status <name>`         | Show container state + pinned commits                     |
| `nelly prune  <name>`         | Delete log files older than `log_retention_days`          |

Pass `-i` after the deployment name to enable confirmation prompts.

## Layout

```
Nelly
├── bin/nelly                          # single CLI entry point
├── lib/
│   ├── common.sh                      # logging, jq helpers, confirm()
│   ├── fetch.sh                       # clone + lockfile
│   ├── build.sh                       # render Dockerfile, build image
│   ├── run.sh                         # docker run (no eval, array args)
│   ├── logs.sh   status.sh   prune.sh
└── containers/
    └── template/                      # copy of this is what `nelly init` makes
        ├── def/
        │   ├── config.json
        │   ├── Dockerfile
        │   └── .env                   # (not committed) runtime secrets
        ├── apps/                      # populated by `nelly fetch`
        └── logs/
            └── cron/                  # per-app cron output (volume-mounted)
```

## Prerequisites

- Docker
- `jq`, `git`, `rsync` on the host

## Notes vs. v1

- `update.sh` and `update_scripts/` are gone; everything goes through `bin/nelly`.
- Cron is now wired end-to-end: each app declares its schedule in `config.json` and Nelly assembles the container crontab at build time.
- Apps no longer share a Python environment — each gets its own venv under `/opt/venvs/<app>`.
- Secrets are mounted, not copied into the image.
- No `read -p` prompts in the default path; `nelly deploy` can be run unattended (cron, CI, SSH one-liner).
- Reproducible: every fetched commit is pinned in `def/commits.lock.json` and images are tagged with the lockfile's hash.

## License

MIT.
