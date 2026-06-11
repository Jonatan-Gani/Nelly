# Nelly Snapshot — Backup Interface

This document describes the **`nelly snapshot`** interface: how to run it, what
it produces, and how an off-site backup layer (restic, borg, …) consumes its
output. It is written to be understood without reading nelly's source.

If you maintain the backup layer and never touch nelly itself, the two sections
you need are [The bundle (data contract)](#the-bundle-data-contract) and
[Integrating a backup layer](#integrating-a-backup-layer).

---

## What this is

Nelly manages Python-job Docker deployments on a host. Each deployment lives in
`containers/<name>/` and has a `config.json`, secrets, a pinned lockfile, and a
running container.

`nelly snapshot` collects **everything required to reconstruct every deployment
on a freshly flashed host** — images, volumes, secrets, config — into a single
directory, in a consistent state. That directory (default `/var/backups/nelly/`)
is the **contract** with the off-site backup layer: the backup tool only has to
copy that one path. Nelly guarantees it appears complete and consistent before
each run.

It does **not** push anything off-site itself. It produces the bundle; restic /
borg / etc. encrypt and ship it.

```
  deployments + containers          nelly snapshot create            off-site layer
┌──────────────────────────┐      ┌───────────────────────┐      ┌────────────────┐
│ containers/<name>/        │      │ quiesce → tar volumes │      │ restic backup  │
│ running docker containers │ ───▶ │ dump config/secrets   │ ───▶ │ (encrypt+dedup)│
│ bind-mounted volumes      │      │ pin image digests     │      │ → off-site     │
└──────────────────────────┘      └───────────────────────┘      └────────────────┘
                                    writes /var/backups/nelly/
```

---

## Quick start

```sh
# 1. Create the bundle directory (holds cleartext secrets between runs → 0700)
sudo install -d -o "$USER" -g "$USER" -m 0700 /var/backups/nelly

# 2. Produce a bundle by hand, then inspect it
nelly snapshot create
nelly snapshot list
nelly snapshot verify

# 3. Wire it to fire before every off-site backup (see "Integrating" below)
sudo mkdir -p /etc/restic/pre-backup.d
nelly snapshot install-hook
```

---

## Command reference

```
nelly snapshot <subcommand> [flags]
```

A bare `nelly snapshot` (no subcommand) prints usage — it does **not** run
`create`, because `create` stops and restarts containers and must never be a
no-arg side effect.

### `create` — build the bundle

```
nelly snapshot create [--out DIR] [--no-quiesce] [--no-volumes] [--no-secrets]
                      [--no-verify] [--quiesce-time N]
                      [--only NAME]... [--exclude NAME]...
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--out DIR` | `/var/backups/nelly` | Where the bundle is written. |
| `--only NAME` | (all) | Restrict to this deployment. Repeatable. A typo'd name **fails loudly** rather than producing an empty bundle. |
| `--exclude NAME` | (none) | Skip this deployment. Repeatable. |
| `--quiesce-time N` | `30` | Seconds passed to `docker stop --time` before tarring a deployment's volumes. |
| `--no-quiesce` | off | Tar volumes **without** stopping the container. Faster, but risks torn files. Each affected volume is flagged `torn: true` in its metadata. |
| `--no-volumes` | off | Skip bind-mount volume capture entirely. |
| `--no-secrets` | off | Exclude `def/.env` and `def/secrets/` from the deployment tarball. By default secrets **are** included (the off-site copy is encrypted). |
| `--no-verify` | off | Skip the post-build self-verification. Not recommended. |

What `create` does, per deployment:

1. Run the `pre_snapshot` hook **while the container is live** (so a DB can
   `pg_dump` into the bundle).
2. Tar the deployment directory (`config.json`, secrets, lockfile, releases,
   Dockerfile) → `tarball.tar`.
3. Record `docker inspect` → `container-inspect.json`, and the image digest →
   `image-digest.txt`.
4. **Quiesce** (`docker stop`), tar each declared bind-mount volume, then
   **restart** (`docker start`).
5. Run the `post_snapshot` hook.

The whole bundle is built in a sibling `<out>.new/` directory and swapped into
place atomically at the end, then self-verified.

### `verify` — check an existing bundle

```
nelly snapshot verify [--out DIR]
```

Structural + integrity check: `BUNDLE_VERSION` matches, `snapshot.json` and
`fleet-manifest.json` are valid JSON, every deployment has a `tarball.tar`,
every volume `.tar` has a matching `.meta.json` (and vice-versa — no orphans),
each volume tarball's `sha256` matches its metadata, and the manifest's
deployment list matches the `deployments/` directories. Exit non-zero on any
problem.

### `list` — summarize the last run

```
nelly snapshot list [--out DIR]      # aliases: ls, status
```

Prints when the bundle was generated, host, duration, size, and per-deployment
outcomes from `snapshot.json`. Add `--json` (global flag) for machine output.

### `install-hook` / `uninstall-hook` — wire to the backup runner

```
nelly snapshot install-hook   [--hook-dir DIR] [--name NAME]
nelly snapshot uninstall-hook [--hook-dir DIR] [--name NAME]
```

Drops (or removes) a small executable script in a `run-parts` directory
(default `/etc/restic/pre-backup.d/`, name `50-nelly-snapshot`) that runs
`nelly snapshot create` in strict mode. See
[Integrating a backup layer](#integrating-a-backup-layer).

### Exit codes (from `create`)

These matter: the backup runner must treat any non-zero as **abort + alert**.

| Code | Meaning |
|------|---------|
| `0` | Bundle complete and self-verified. Safe to back up. |
| `1` | One or more deployments failed (e.g. a missing volume path, a failed `pre_snapshot` hook), **or** a fatal setup error (lock contention, bad `--only`, unwritable `--out`). Per-deployment outcomes are in `snapshot.json`. |
| `3` | Bundle failed self-verification. **Do not** back it up. |

---

## The bundle (data contract)

Everything below appears under `--out` (default `/var/backups/nelly/`). The
directory is mode `0700`; files are `0600`. Volume and deployment tarballs are
**uncompressed** and deterministic (`--format=gnu --sort=name --numeric-owner`)
so restic/borg chunk-dedup works run-to-run.

```
/var/backups/nelly/
├── BUNDLE_VERSION                      # schema version, currently "1"
├── README.txt                          # restore instructions (self-contained)
├── snapshot.log                        # full log of the run that built this bundle
├── snapshot.json                       # run metadata + per-deployment outcomes
├── fleet-manifest.json                 # "what was running" — the rebuild source of truth
├── deployments/
│   └── <name>/
│       ├── tarball.tar                 # full deployment dir incl. secrets
│       ├── container-inspect.json      # `docker inspect` output (see security note)
│       ├── image-digest.txt            # line 1: image ref; line 2 (local builds): image ID
│       ├── dumps/                      # pre_snapshot hook output (pg_dump, etc.)
│       └── volumes/
│           ├── <slug>.tar              # one per bind-mount, taken while quiesced
│           ├── <slug>.meta.json        # path/sha256/size/torn for each volume tar
│           └── skipped-volumes.json    # volumes deliberately not tarred (see skip_volumes)
└── nelly-state/
    ├── bot.tar                         # Telegram bot state, if present
    └── nelly-commit.txt                # git HEAD of nelly itself at snapshot time
```

### `fleet-manifest.json`

The single document a human (or script) rebuilds the fleet from.

```jsonc
{
  "schema_version": 1,
  "generated_at": "2026-06-11T03:00:00Z",
  "host": "pi-01",
  "nelly_root": "/home/pi/nelly",
  "nelly_version": "0.5.0",
  "nelly_commit": "01c2ca2…",
  "deployments": [
    {
      "name": "scraper",
      "container_name": "scraper",
      "image": "scraper:abc123",            // tag nelly built/ran
      "image_repo_digest": "scraper@sha256:…", // null if never pushed to a registry
      "image_id": "sha256:…",               // local image ID (anchor for local-only builds)
      "base_image": "python:3.11-slim@sha256:…",
      "state": "running",                   // docker state at snapshot time
      "running_image_id": "sha256:…",
      "started_at": "2026-06-01T12:00:00Z",
      "tags": ["prod"],
      "apps": [
        { "name": "fetch", "source": {"type":"git","url":"…","ref":"main"},
          "schedule": "*/15 * * * *", "entrypoint": "run.py",
          "commit": "deadbeef…" }          // exact commit from the lockfile
      ],
      "network": { "name": "nelly_net", "ports": [], "extra": [],
                   "aliases": [], "hostname": null, "static_ip": null },
      "volumes": ["/srv/scraper/data:/data:rw"],
      "backup": { "skip_volumes": [] },
      "resources": { "cpus": "1.0", "memory": "512m" },
      "health": { … },
      "restart": "unless-stopped",
      "env_files": [
        { "path": "/home/pi/nelly/containers/scraper/def/.env", "purpose": "global" }
      ]
    }
  ]
}
```

`env_files` lists the **absolute host paths** of the secret files, so the backup
side knows which files matter even though the secrets are also inside
`tarball.tar`. If a deployment's config can't be parsed, its entry is replaced
with `{ "name": "<name>", "error": "manifest generation failed" }` and the rest
of the fleet still records.

### `snapshot.json`

Run metadata. The backup runner can parse `deployments_failed` for alerting.

```jsonc
{
  "schema_version": 1,
  "started_at": "2026-06-11T03:00:00Z",
  "finished_at": "2026-06-11T03:00:42Z",
  "duration_seconds": 42,
  "host": "pi-01",
  "size_bytes": 1048576,
  "deployments_total": 3,
  "deployments_ok": 3,
  "deployments_failed": 0,
  "options": { "quiesce": true, "volumes": true, "secrets": true,
               "quiesce_time_seconds": 30 },
  "results": [
    { "deployment": "scraper", "outcome": "success", "duration_seconds": 12, "error": null }
    // outcome: "success" | "failed"
  ]
}
```

### `volumes/<slug>.meta.json`

```jsonc
{
  "host_path": "/srv/scraper/data",   // where to restore it
  "container_path": "/data",
  "mode": "rw",                        // or null
  "sha256": "…",                       // of the .tar (verify checks this)
  "size_bytes": 1234,
  "torn": false                        // true only if tarred live and a file changed mid-read
}
```

The `<slug>` filename is a sanitized host path plus an 8-char hash, so two
different paths never collide. Restore reads `host_path` from the metadata, not
the filename.

### Security note

`tarball.tar` and `container-inspect.json` contain **secrets in cleartext**
(env files; `container-inspect.json` includes the container's environment). This
is intentional: the bundle is mode `0700`, and it is only meant to leave the
machine inside the backup layer's **client-side-encrypted** repository. Do not
expose `/var/backups/nelly/` over an unencrypted channel or a
world-readable mount. Secrets should *also* live in your password manager / sops
per your secrets discipline — the bundle is for disaster recovery, not the
primary store.

---

## Integrating a backup layer

`install-hook` drops a strict-mode (`set -euo pipefail`) script that runs
`nelly snapshot create`. Its non-zero exit codes are the integration point.

**The backup runner must run the hook directory before the off-site copy, and
abort + alert on any non-zero exit.** Otherwise a stale or corrupt bundle
silently ships, and you only discover it at restore time.

A minimal restic-side wiring:

```sh
# before `restic backup`:
if ! run-parts --exit-on-error /etc/restic/pre-backup.d/; then
    curl -fsS --retry 3 "$HEALTHCHECKS_URL/fail" >/dev/null || true
    exit 1                       # do NOT proceed to restic backup
fi

restic backup /var/backups/nelly   # + your other declared paths
```

Why a pre-backup hook and not a separate timer: it makes bundle freshness
**synchronous** with the backup. The alternative (nelly on its own cron, hoping
it finishes before the backup timer fires) is timing-fragile.

---

## Configuration (per deployment)

Two parts of a deployment's `config.json` affect snapshots. Both are optional.

### `hooks.pre_snapshot` / `hooks.post_snapshot`

Host-side scripts, paths relative to the deployment directory (same security
rules and `nelly help` semantics as `pre_deploy` / `post_deploy`: no absolute
paths, no `..`, must stay inside the deployment dir).

- `pre_snapshot` runs **before** the container is quiesced — the moment to take
  a logical database dump from the live container.
- `post_snapshot` runs after the volumes are tarred and the container is back up.

A non-zero `pre_snapshot` **fails that deployment's snapshot** (so a failed dump
can't leave a silently incomplete bundle). `post_snapshot` failures are warned
but not fatal.

Hook environment (in addition to nelly's usual hook vars):

| Variable | Value |
|----------|-------|
| `NELLY_DEPLOYMENT` | Deployment name |
| `NELLY_DEPLOY_DIR` | Absolute path to the deployment directory |
| `NELLY_HOOK` | `pre_snapshot` or `post_snapshot` |
| `NELLY_SNAPSHOT_DIR` | This deployment's bundle dir, e.g. `/var/backups/nelly.new/deployments/<name>/`. **Drop dumps into `$NELLY_SNAPSHOT_DIR/dumps/`.** |

### `backup.skip_volumes`

A list of **absolute host paths** to exclude from quiesce-tarring — use this for
a database whose data dir is already captured by a `pre_snapshot` logical dump,
so you don't ship the DB twice (once as a clean dump, once as a heavier,
torn-prone on-disk copy). Validated as absolute, no `..`. Skipped volumes are
recorded in `volumes/skipped-volumes.json`.

```jsonc
// containers/<name>/def/config.json
{
  "hooks": { "pre_snapshot": "./def/hooks/pgdump.sh" },
  "backup": { "skip_volumes": ["/var/lib/postgresql/data"] }
}
```

```sh
# def/hooks/pgdump.sh
#!/usr/bin/env bash
set -euo pipefail
docker exec "$NELLY_DEPLOYMENT" pg_dumpall -U postgres \
    > "$NELLY_SNAPSHOT_DIR/dumps/pg_dumpall.sql"
```

---

## Restore (on a freshly flashed host)

The bundle's own `README.txt` carries this too. In short:

```sh
# 1. Install nelly at the exact commit the bundle was made with
git clone <repo> ~/nelly && cd ~/nelly
git checkout "$(cat /restore/nelly-state/nelly-commit.txt)"
bash install.sh

# 2. Recreate each deployment
for t in /restore/deployments/*/tarball.tar; do
    nelly restore "$t"
done

# 3. Restore each volume to its recorded host path
for v in /restore/deployments/*/volumes/*.tar; do
    meta="${v%.tar}.meta.json"
    dest="$(jq -r .host_path "$meta")"
    sudo mkdir -p "$(dirname "$dest")"
    sudo tar -xf "$v" -C "$(dirname "$dest")"
done

# 4. Apply any logical DB dumps from deployments/<name>/dumps/ per the DB's
#    own restore procedure (e.g. psql < pg_dumpall.sql)

# 5. Bring each deployment up, then check it against fleet-manifest.json
nelly deploy <name>
```

Acceptance test for a complete bundle: *given only the off-site repo and the
password manager, on a freshly flashed host, can you reconstruct every container
nelly managed — same images, same volumes, same secrets — without guessing?*

---

## Consistency guarantees

- **Quiesce, not liveness.** Volumes are tarred while the container is stopped,
  then it is restarted. Never walks a live volume by default.
- **Always-restart.** If a snapshot is interrupted (error, `Ctrl-C`, `SIGTERM`)
  after a container is stopped, a guard restarts it before exiting. A backup run
  never leaves a service down.
- **Atomic bundle.** Built in `<out>.new/`, swapped into place at the end. A
  reader of `<out>` never sees a half-built bundle; the previous good bundle
  stays until the new one is complete.
- **Self-verifying.** `create` runs `verify` before returning; a corrupt bundle
  exits `3` so the backup run aborts that night, not at restore time.
- **Serialized.** A global lock (`<out>.lock`) prevents two concurrent `create`
  runs; a per-deployment lock prevents snapshotting a container mid-`deploy`.
- **Fail-loud.** A missing volume path, a failed dump, or an unrestartable
  container marks the deployment `failed` and makes `create` exit non-zero.

---

## Defaults and environment variables

| Setting | Default | Override |
|---------|---------|----------|
| Bundle directory | `/var/backups/nelly` | `--out`, or `NELLY_BACKUP_DIR` |
| Hook directory | `/etc/restic/pre-backup.d` | `--hook-dir`, or `NELLY_RESTIC_HOOK_DIR` |
| Hook script name | `50-nelly-snapshot` | `--name` |
| Quiesce timeout | `30` seconds | `--quiesce-time N` |

**Requirements:** `bash`, `jq`, `tar` (GNU), `sha256sum`, and `docker` for the
quiesce/inspect steps. `flock` enables the concurrency locks (degrades to no
locking if absent, matching the rest of nelly).
