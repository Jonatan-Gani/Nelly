#!/usr/bin/env bash
# install.sh — bootstrap Nelly on a Debian (or Ubuntu) host.
#
# Run from a checked-out copy of the repo:
#
#   git clone <repo> ~/nelly && cd ~/nelly && bash install.sh
#
# What this does:
#   1. Checks the OS is Debian/Ubuntu-family.
#   2. Installs the host packages Nelly needs (jq, git, rsync, curl,
#      ca-certificates, python3) via apt — sudo will be prompted for.
#   3. Installs Docker Engine from the official Docker repo if `docker` is
#      not already on $PATH. (Skip with: NELLY_SKIP_DOCKER=1)
#   4. Adds the current user to the `docker` group if needed.
#   5. Creates ~/.local/bin and symlinks `nelly` there.
#   6. Ensures ~/.local/bin is on $PATH in ~/.bashrc.
#   7. Verifies `nelly --version` runs.
#
# Idempotent: safe to re-run.

set -euo pipefail

# ---- helpers ---------------------------------------------------------------

bold()    { [[ -t 1 ]] && printf '\033[1m%s\033[0m' "$*" || printf '%s' "$*"; }
green()   { [[ -t 1 ]] && printf '\033[32m%s\033[0m' "$*" || printf '%s' "$*"; }
yellow()  { [[ -t 1 ]] && printf '\033[33m%s\033[0m' "$*" || printf '%s' "$*"; }
red()     { [[ -t 1 ]] && printf '\033[31m%s\033[0m' "$*" || printf '%s' "$*"; }
say()     { printf '%s %s\n' "$(green '==>')"  "$*"; }
warn()    { printf '%s %s\n' "$(yellow '!!')" "$*" >&2; }
die()     { printf '%s %s\n' "$(red 'ERROR:')" "$*" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
NELLY_BIN="$REPO_DIR/bin/nelly"

[[ -x "$NELLY_BIN" ]] || die "$NELLY_BIN not found — run install.sh from inside a Nelly checkout"

# ---- 1. OS detection -------------------------------------------------------

say "checking the OS"
if [[ ! -r /etc/os-release ]]; then
    die "cannot read /etc/os-release; this installer targets Debian/Ubuntu"
fi
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) say "detected $PRETTY_NAME" ;;
    *) warn "this installer is written for Debian/Ubuntu; YMMV on '$ID'"
       read -r -p "Continue anyway? [y/N] " ans
       [[ "$ans" =~ ^[yY] ]] || exit 1 ;;
esac

# ---- 2. host packages ------------------------------------------------------

say "installing host dependencies via apt"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
    jq git rsync curl ca-certificates python3

# ---- 3. Docker Engine ------------------------------------------------------

if [[ "${NELLY_SKIP_DOCKER:-0}" == "1" ]]; then
    say "NELLY_SKIP_DOCKER=1 — skipping Docker install"
elif command -v docker >/dev/null 2>&1; then
    say "docker already installed: $(docker --version)"
else
    say "installing Docker Engine from the official Docker repo"
    # Per https://docs.docker.com/engine/install/debian/
    sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        # Pick the right vendor URL based on detected family
        DOCKER_VENDOR="debian"
        case "${ID:-}" in ubuntu) DOCKER_VENDOR="ubuntu" ;; esac
        sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_VENDOR}/gpg" \
            -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/${DOCKER_VENDOR} ${VERSION_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
    fi
    sudo apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
    say "docker installed: $(docker --version)"
fi

# ---- 4. docker group -------------------------------------------------------

if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    say "$USER is already in the docker group"
else
    say "adding $USER to the docker group (you will need to log out and back in)"
    sudo usermod -aG docker "$USER"
    NEEDS_RELOGIN=1
fi

# ---- 5. symlink nelly into $HOME/.local/bin --------------------------------

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
ln -sf "$NELLY_BIN" "$LOCAL_BIN/nelly"
say "symlinked $LOCAL_BIN/nelly → $NELLY_BIN"

# ---- 6. PATH ---------------------------------------------------------------

if ! echo ":$PATH:" | grep -q ":$LOCAL_BIN:"; then
    case "$SHELL" in
        */zsh)  RC="$HOME/.zshrc"  ;;
        */bash) RC="$HOME/.bashrc" ;;
        *)      RC="$HOME/.profile" ;;
    esac
    if ! grep -q '\.local/bin' "$RC" 2>/dev/null; then
        printf '\n# Added by nelly install.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$RC"
        say "added ~/.local/bin to PATH in $RC"
    fi
    warn "open a new shell (or run: source $RC) to pick up the PATH change"
fi

# ---- 7. verify -------------------------------------------------------------

say "verifying"
if "$NELLY_BIN" --version; then
    say "$(green 'nelly is installed.')"
else
    die "nelly --version failed"
fi

cat <<EOF

$(bold 'Next steps:')

  $(bold 'nelly init <name>')          # walks you through your first deployment
  $(bold 'nelly --help')               # full command reference
  $(bold 'cat INSTALL.md')             # full installation guide

$(bold 'Docs:')
  README.md       — concepts, recipes, configuration reference
  INSTALL.md      — detailed installation + post-install configuration
  tests/smoke.sh  — offline smoke suite (try: bash tests/smoke.sh)
EOF

if [[ "${NEEDS_RELOGIN:-0}" == "1" ]]; then
    cat <<EOF

$(yellow '⚠  IMPORTANT:') you were just added to the docker group.
$(yellow '   Log out and back in (or run:  newgrp docker) before')
$(yellow '   running any nelly command that needs docker.')

Confirm with:  $(bold 'docker run --rm hello-world')
EOF
fi
