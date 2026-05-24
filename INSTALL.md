# Installing Nelly on Debian (or Ubuntu)

This is the canonical install guide. It targets **Debian 11 (bullseye) or
newer** and **Ubuntu 22.04 LTS or newer** running on x86_64 or arm64. Other
Linux distros work but you'll need to translate the apt commands.

There are two paths: the **one-shot bootstrap** (recommended) and the
**manual install** (do this if you want to know exactly what's happening or
you can't / don't want to run a script).

After install, jump to [First deployment](#first-deployment) to confirm
everything works.

---

## Contents

1. [Before you start](#before-you-start)
2. [One-shot install](#one-shot-install)
3. [Manual install (step by step)](#manual-install-step-by-step)
4. [First deployment](#first-deployment)
5. [Telegram bot (optional)](#telegram-bot-optional)
6. [Persistent user services (optional)](#persistent-user-services-optional)
7. [Updating Nelly](#updating-nelly)
8. [Uninstalling](#uninstalling)
9. [Troubleshooting](#troubleshooting)

---

## Before you start

| Requirement | Why |
|---|---|
| Debian 11+ or Ubuntu 22.04+ | Tested target. Docker Engine official repo supports both. |
| **sudo** access | To install Docker + system packages. Nelly itself runs as your regular user. |
| 1–2 GB free disk | Docker images are the biggest consumer. Nelly auto-prunes old images. |
| x86_64 or arm64 host | Both work. ARM Raspberry Pis are great Nelly hosts. |
| Outbound internet to GitHub + DockerHub | For cloning your app repos and pulling base images. |

You do **not** need root to use Nelly itself. The bootstrap script uses
`sudo` only for installing system packages and adding you to the `docker`
group. Once installed, every Nelly command runs as your regular user.

---

## One-shot install

```sh
# Pick a checkout location (your home dir is fine; ~/nelly is conventional)
cd ~
git clone https://github.com/Jonatan-Gani/Nelly.git nelly
cd nelly

# Run the bootstrap. It'll prompt for your sudo password once.
bash install.sh
```

What the bootstrap does:

1. Confirms you're on a Debian/Ubuntu-family OS.
2. `apt install` `jq git rsync curl ca-certificates python3`.
3. Installs **Docker Engine** from the official Docker repo (skip with
   `NELLY_SKIP_DOCKER=1 bash install.sh` if you've already got it).
4. Adds your user to the `docker` group.
5. Symlinks `bin/nelly` into `~/.local/bin/nelly`.
6. Ensures `~/.local/bin` is on your `PATH` (edits `~/.bashrc` /
   `~/.zshrc` / `~/.profile`).
7. Runs `nelly --version` to confirm it worked.

**If the script added you to the docker group**, log out and back in
(or run `newgrp docker` in your current shell), then verify:

```sh
docker run --rm hello-world
nelly --version       # → "nelly 0.5.0"
```

That's it. Skip to [First deployment](#first-deployment).

---

## Manual install (step by step)

Do this if you want to verify each step, or you can't run the bootstrap.

### 1. Update apt and install host packages

```sh
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    jq git rsync curl ca-certificates python3
```

What each one is for:

- `jq` — JSON parsing, used throughout Nelly's bash code.
- `git` — fetching app source.
- `rsync` — copying app source into the build context.
- `curl` — Telegram API + Docker repo signing key.
- `ca-certificates` — TLS roots for HTTPS to GitHub / Docker / Telegram.
- `python3` — `nelly cron --next N` (next-run preview) and the Telegram bot.

### 2. Install Docker Engine

The version in the default Debian/Ubuntu repos is older than what Docker
publishes. Use Docker's official repo:

```sh
# Trust Docker's signing key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the Docker repo (for Ubuntu, swap "debian" → "ubuntu")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine + buildx + compose plugins
sudo apt-get update
sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Start it now, and on boot
sudo systemctl enable --now docker

# Verify
sudo docker run --rm hello-world
```

### 3. Add yourself to the `docker` group

So you can talk to the Docker daemon without `sudo`:

```sh
sudo usermod -aG docker "$USER"

# Apply the new group to your current shell (or just log out and back in)
newgrp docker

# Verify — should print "Hello from Docker!" without sudo
docker run --rm hello-world
```

> **Heads up — security:** the `docker` group is effectively root. Any
> member can `docker run -v /:/host …` and read/write your entire
> filesystem. This is fine on a personal server you control; don't add
> users you don't fully trust. Nelly's config validator blocks this from
> happening through Nelly itself, but the group membership is yours to
> manage.

### 4. Clone Nelly

```sh
cd ~
git clone https://github.com/Jonatan-Gani/Nelly.git nelly
cd nelly
```

(You can clone it anywhere — `/opt/nelly`, `/srv/nelly`, etc. The rest of
this guide assumes `~/nelly`. Nelly stores all its state under that
directory; no global config files.)

### 5. Put `nelly` on your PATH

```sh
mkdir -p ~/.local/bin
ln -sf ~/nelly/bin/nelly ~/.local/bin/nelly

# Make sure ~/.local/bin is on PATH. On Debian, login shells already include it,
# but interactive non-login shells often don't. Add it explicitly:
if ! grep -q '\.local/bin' ~/.bashrc 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> ~/.bashrc
fi

# Reload your shell
exec bash
```

### 6. Verify

```sh
nelly --version              # → "nelly 0.5.0"
nelly                        # short intro screen
nelly help                   # full reference
bash tests/smoke.sh          # 122 offline assertions; should take ~5s
```

If `bash tests/smoke.sh` passes, your install is healthy.

---

## First deployment

Walk through a tiny but real deployment to confirm the whole pipeline
works on your box.

```sh
# 1. Scaffold (-y skips the wizard's prompts; sensible defaults applied)
nelly init hello -y

# 2. Make a tiny Python "app" living locally
mkdir -p ~/dev/hello-nelly
cat > ~/dev/hello-nelly/hi.py <<'PY'
import os, sys, datetime
greeting = os.environ.get("GREETING", "world")
print(f"[{datetime.datetime.utcnow().isoformat()}] hello, {greeting}!")
sys.exit(0)
PY

# 3. Tell Nelly about it. Local source = rsynced from a path on this host.
nelly app add hello \
    --name greeter \
    --local ~/dev/hello-nelly \
    --schedule "*/1 * * * *" \
    --entrypoint hi.py

# 4. Add a secret. (You'll be asked for the value — type "Debian" and press Enter.)
nelly secrets set hello GREETING

# 5. Pin the base image to a digest so future builds are reproducible.
nelly base-image-pin hello

# 6. See what the deploy will do, no side effects.
nelly plan hello

# 7. Pre-flight check.
nelly doctor hello

# 8. Deploy. Waits up to 60s for cron to be healthy; rolls back if not.
nelly deploy hello --wait-healthy 60 --auto-rollback

# 9. Check it's running.
nelly status hello
nelly cron   hello
nelly logs   hello

# 10. After a minute or two, see the metrics:
nelly metrics hello

# 11. See the release record:
nelly release list hello
nelly release show hello
```

If `nelly status` shows the container is **running** and `nelly metrics`
shows at least one entry for `greeter` with `rc=0`, you're done. Nelly
will keep running your script every minute until you stop it.

To clean up the test:
```sh
nelly stop  hello
docker rm -f hello
rm -rf ~/nelly/containers/hello ~/dev/hello-nelly
```

---

## Telegram bot (optional)

If you want to monitor (and optionally trigger lifecycle actions) from
your phone, see the [Telegram bot section in the
README](README.md#telegram-bot-optional-secure-remote-monitoring) for
the full setup. Short version:

```sh
nelly bot setup                      # interactive: token + auto-detect your user id
nelly bot install-systemd            # writes ~/.config/systemd/user/nelly-bot.service
systemctl --user daemon-reload
systemctl --user enable --now nelly-bot
sudo loginctl enable-linger "$USER"  # so the bot keeps running after you log out

# Confirm
nelly bot status
systemctl --user status nelly-bot
```

Then on your phone, message your bot with `/help`.

---

## Persistent user services (optional)

By default, **systemd user services stop when you log out**. If you want
the Telegram bot (or any user systemd unit) to keep running while you're
not logged in, enable lingering for your account:

```sh
sudo loginctl enable-linger "$USER"
```

Verify:

```sh
loginctl show-user "$USER" --property=Linger
# Linger=yes
```

This makes systemd start your user instance at boot and keep it running
across logouts.

---

## Updating Nelly

```sh
cd ~/nelly
git pull
bash tests/smoke.sh         # confirm nothing regressed
```

That's it. Nelly is a stateless CLI — there's no migration step. Per-deployment
state lives under `containers/<name>/`; bot state lives under `bot/`;
neither is touched by `git pull`.

If you want to verify against a real Docker daemon:
```sh
bash tests/e2e.sh           # full pipeline test, ~3-5 min
```

---

## Uninstalling

```sh
# 1. Stop all your deployments
for d in $(nelly list --json | jq -r '.[].deployment'); do
    nelly stop "$d" || true
    docker rm -f "$d" 2>/dev/null || true
done

# 2. (optional) stop the Telegram bot
systemctl --user disable --now nelly-bot 2>/dev/null || true
rm -f ~/.config/systemd/user/nelly-bot.service

# 3. Remove the symlink + repo
rm -f ~/.local/bin/nelly
rm -rf ~/nelly

# 4. (optional) remove the docker repo + packages
# Skip this if you use Docker for other things!
sudo systemctl disable --now docker
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
sudo apt-get autoremove -y

# 5. (optional) remove yourself from the docker group
sudo gpasswd -d "$USER" docker
```

---

## Troubleshooting

### `permission denied while trying to connect to the Docker daemon`

You're not in the `docker` group yet. Either log out and back in, or run
`newgrp docker` in your current shell. Verify with `docker ps`.

### `nelly: command not found`

`~/.local/bin` isn't on your `PATH`. Either:
```sh
exec bash                            # reload your rc files
# or, immediately:
export PATH="$HOME/.local/bin:$PATH"
```

### `bash tests/smoke.sh` fails on `shellcheck`

`shellcheck` isn't installed. That's fine — it's optional. The smoke
suite skips the `shellcheck` section if the binary isn't there. If you
want it:
```sh
sudo apt-get install -y shellcheck
```

### `nelly deploy` fails with `missing required commands: rsync`

```sh
sudo apt-get install -y rsync
```

### Docker pulls fail with TLS errors

Older `ca-certificates` package, or your system clock is way off. Fix
with:
```sh
sudo apt-get install --reinstall -y ca-certificates
sudo timedatectl set-ntp true
```

### `flock: another nelly run is in progress`

Another `nelly deploy`/`fetch`/`build`/`run` is holding the
per-deployment lock. Wait for it (Nelly blocks automatically), or — if
you're certain it's stale — `rm containers/<name>/.nelly.lock`. **Never
do this while a deploy is actually running.**

### Container restarts in a loop after deploy

The cron healthcheck (`pgrep -x cron`) requires `cron` to be installed
inside the image. Nelly's template Dockerfile installs it via apt; if
you've replaced the Dockerfile, make sure `cron` is still there.

```sh
nelly inspect hello
docker logs hello
nelly shell hello       # have a look around
```

### A scheduled job isn't running

Check the assembled crontab:
```sh
nelly cron hello
nelly shell hello -- cat /etc/cron.d/nelly
nelly logs  hello hi    # tail one app's cron output
```

Common causes:
- entrypoint path is wrong (`nelly app show hello hi` to see what's set)
- The Python script raises before doing anything visible (check `<app>.log`)
- requirements.txt has an unpinned package that resolved differently than
  expected — `nelly doctor` warns about this

### `nelly bot setup` can't auto-detect my user id

Your account hasn't messaged the bot yet, or you waited too long. Just
provide it manually — message `@userinfobot` on Telegram to get your
numeric user id and paste it into the wizard. You can also add allowed
users later:
```sh
nelly bot allow 123456789
```

### Disk filling up

Old Docker images should auto-prune after each successful deploy, but if
you've had a lot of failed builds you may have orphan images:
```sh
nelly image-prune hello --dry-run    # see what would go
nelly image-prune hello              # remove them
```

You can also clear release history (keeping the manifests is cheap, but
the per-release log copies add up):
```sh
nelly release prune hello --keep 20
```

And rotate the in-container logs:
```sh
nelly prune hello                    # deletes .log + .metrics.jsonl older than retention
```

---

## Where things live on disk

After install:

```
~/nelly/                         the repo
├── bin/nelly                    the CLI (symlinked from ~/.local/bin/nelly)
├── lib/*.sh, lib/*.py           implementation modules
├── containers/<deployment>/     per-deployment state (config, secrets, logs)
└── bot/                         per-host bot state (token, allowed_users, audit log)

~/.config/systemd/user/nelly-bot.service   (if you ran nelly bot install-systemd)
```

Nelly never writes outside `~/nelly` (except the systemd user unit and the
optional `~/.bashrc` PATH addition). Backups produced with `nelly backup`
are deposited into the current directory unless you pass `--out PATH`.

---

## Now what

- The README's [Five-minute tutorial](README.md#five-minute-tutorial) walks
  through the guided flow.
- The README's [Recipes](README.md#recipes) has 10+ worked examples for
  common operations.
- `nelly help` is the command reference; `nelly help <command>` gives per-
  command detail.
- `nelly doctor <name>` is the pre-flight you should run before each new
  deploy to spot issues early.
