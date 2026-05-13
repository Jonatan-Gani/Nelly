#!/usr/bin/env bash
# Build the Docker image for a deployment.
# - Per-app venvs under /opt/venvs/<app>
# - Crontab assembled from apps[].schedule + apps[].entrypoint
# - Image tagged with deployment name + short SHA of the lockfile
set -euo pipefail

DEPLOY_DIR="$1"
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
DOCKERFILE="$DEPLOY_DIR/def/Dockerfile"
LOCKFILE="$DEPLOY_DIR/def/commits.lock.json"
APPS_DIR="$DEPLOY_DIR/apps"
BUILD_DIR="$DEPLOY_DIR/.build"
LOG_FILE="$DEPLOY_DIR/logs/build.log"

mkdir -p "$BUILD_DIR" "$(dirname "$LOG_FILE")"
exec > >(log_to "$LOG_FILE") 2>&1

require_cmd jq docker
[[ -f "$CONFIG" ]]     || die "config not found: $CONFIG"
[[ -f "$DOCKERFILE" ]] || die "Dockerfile not found: $DOCKERFILE"

IMAGE_NAME="$(jqget "$CONFIG" '.image_name' 'nelly-app')"
PROJECT_NAME="$(jqget "$CONFIG" '.container_name' 'nelly')"

# Assemble crontab from per-app schedule + entrypoint.
CRONTAB="$BUILD_DIR/crontab"
: > "$CRONTAB"
{
    echo "SHELL=/bin/bash"
    echo "PATH=/usr/local/bin:/usr/bin:/bin"
    echo
} >> "$CRONTAB"

mapfile -t APPS < <(jq -c '.apps[]' "$CONFIG")
for app in "${APPS[@]}"; do
    name="$(echo "$app"    | jq -r '.app_name')"
    sched="$(echo "$app"   | jq -r '.schedule // empty')"
    entry="$(echo "$app"   | jq -r '.entrypoint // empty')"
    [[ -d "$APPS_DIR/$name" ]] || die "missing fetched app: $name (run: nelly fetch …)"

    if [[ -z "$sched" || -z "$entry" ]]; then
        warn "app $name has no schedule/entrypoint; it will be installed but not scheduled"
        continue
    fi

    venv="/opt/venvs/$name"
    work="/home/apps/$name"
    log="/var/log/nelly/$name.log"
    cmd="cd $work && $venv/bin/python $entry"

    # Cron lines must end with newline; load env from /etc/nelly/<name>.env at run time.
    echo "$sched root /usr/local/bin/nelly-run $name >> $log 2>&1" >> "$CRONTAB"
done

# Per-app pip install lines, injected into Dockerfile.
REQS_FRAG="$BUILD_DIR/requirements.frag"
: > "$REQS_FRAG"
for app in "${APPS[@]}"; do
    name="$(echo "$app" | jq -r '.app_name')"
    if [[ -f "$APPS_DIR/$name/requirements.txt" ]]; then
        {
            echo "RUN python -m venv /opt/venvs/$name \\"
            echo " && /opt/venvs/$name/bin/pip install --no-cache-dir --upgrade pip \\"
            echo " && /opt/venvs/$name/bin/pip install --no-cache-dir -r /home/apps/$name/requirements.txt"
        } >> "$REQS_FRAG"
    else
        echo "RUN python -m venv /opt/venvs/$name" >> "$REQS_FRAG"
    fi
done

# OS packages from config.packages[].
PKG_FRAG="$BUILD_DIR/packages.frag"
mapfile -t PKGS < <(jq -r '.packages[]?' "$CONFIG")
if [[ ${#PKGS[@]} -gt 0 ]]; then
    # Validate package names — letters, digits, dash, dot, plus, underscore only.
    for p in "${PKGS[@]}"; do
        [[ "$p" =~ ^[a-zA-Z0-9._+-]+$ ]] || die "invalid package name: $p"
    done
    printf 'RUN apt-get update && apt-get install -y --no-install-recommends %s \\\n && rm -rf /var/lib/apt/lists/*\n' \
        "${PKGS[*]}" > "$PKG_FRAG"
else
    : > "$PKG_FRAG"
fi

# Stage build context: Dockerfile (rendered), apps/, crontab, fragments.
STAGE="$BUILD_DIR/ctx"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -r "$APPS_DIR" "$STAGE/apps"
cp "$CRONTAB"     "$STAGE/crontab"

# Render the Dockerfile by substituting two placeholders.
awk -v pkgs="$(cat "$PKG_FRAG")" -v reqs="$(cat "$REQS_FRAG")" '
    /# NELLY: SYSTEM_PACKAGES/ { print pkgs; next }
    /# NELLY: APP_VENVS/       { print reqs; next }
    { print }
' "$DOCKERFILE" > "$STAGE/Dockerfile"

# Tag image with short hash of lockfile so we can roll back.
TAG="$(sha256sum "$LOCKFILE" 2>/dev/null | cut -c1-12)"
[[ -n "$TAG" ]] || TAG="latest"
FULL_IMAGE="${IMAGE_NAME}:${TAG}"

info "building $FULL_IMAGE"
docker build \
    --build-arg PROJECT_NAME="$PROJECT_NAME" \
    -t "$FULL_IMAGE" \
    -t "${IMAGE_NAME}:latest" \
    "$STAGE"

info "built $FULL_IMAGE (also tagged :latest)"
echo "$FULL_IMAGE" > "$DEPLOY_DIR/def/last_image.txt"
