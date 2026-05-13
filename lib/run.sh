#!/usr/bin/env bash
# (Re)start the container for a deployment.
# Secrets are mounted from def/.env at run time — never baked into the image.
set -euo pipefail

DEPLOY_DIR="$1"
# shellcheck source=common.sh
source "$(dirname "$(realpath "$0")")/common.sh"

CONFIG="$DEPLOY_DIR/def/config.json"
ENV_FILE="$DEPLOY_DIR/def/.env"
LOG_FILE="$DEPLOY_DIR/logs/run.log"
mkdir -p "$(dirname "$LOG_FILE")" "$DEPLOY_DIR/logs/cron"
exec > >(log_to "$LOG_FILE") 2>&1

require_cmd jq docker
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

CONTAINER_NAME="$(jqget "$CONFIG" '.container_name' 'nelly')"
IMAGE_TAG="$(cat "$DEPLOY_DIR/def/last_image.txt" 2>/dev/null || jqget "$CONFIG" '.image_name' 'nelly-app'):latest"
NETWORK="$(jqget "$CONFIG"   '.network.network_name' '')"
SUBNET="$(jqget "$CONFIG"    '.network.subnet' '')"
GATEWAY="$(jqget "$CONFIG"   '.network.gateway' '')"
STATIC_IP="$(jqget "$CONFIG" '.network.static_ip' '')"

# Build docker run as an array — no eval.
declare -a DOCKER_ARGS=(run -d --restart unless-stopped --name "$CONTAINER_NAME")

if [[ -n "$NETWORK" ]]; then
    if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
        info "creating network $NETWORK"
        declare -a NET_ARGS=(network create --driver bridge)
        [[ -n "$SUBNET"  ]] && NET_ARGS+=(--subnet  "$SUBNET")
        [[ -n "$GATEWAY" ]] && NET_ARGS+=(--gateway "$GATEWAY")
        NET_ARGS+=("$NETWORK")
        docker "${NET_ARGS[@]}"
    fi
    DOCKER_ARGS+=(--network "$NETWORK")
    [[ -n "$STATIC_IP" ]] && DOCKER_ARGS+=(--ip "$STATIC_IP")
fi

# Port publishing comes from config.network.ports[] — explicit, not a free-text blob.
mapfile -t PORTS < <(jq -r '.network.ports[]?' "$CONFIG")
for p in "${PORTS[@]}"; do
    [[ "$p" =~ ^[0-9]+:[0-9]+(/(tcp|udp))?$ ]] || die "invalid port mapping: $p"
    DOCKER_ARGS+=(-p "$p")
done

# Secrets: mount the entire .env at runtime.
if [[ -f "$ENV_FILE" ]]; then
    DOCKER_ARGS+=(--env-file "$ENV_FILE")
else
    warn "no $ENV_FILE — apps will run without secrets"
fi

# Persistent volumes: logs go out to the host so cron output survives rebuilds.
DOCKER_ARGS+=(
    -v "$DEPLOY_DIR/logs/cron:/var/log/nelly"
    "$IMAGE_TAG"
)

# Stop+remove existing container if present.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    if confirm "container $CONTAINER_NAME exists; replace?"; then
        info "stopping $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true
    else
        die "aborted by user"
    fi
fi

info "starting $CONTAINER_NAME from $IMAGE_TAG"
docker "${DOCKER_ARGS[@]}"
info "container $CONTAINER_NAME is up"
