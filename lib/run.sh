#!/usr/bin/env bash
# lib/run.sh — (re)start a deployment's container.
# - Secrets mounted at runtime (never baked).
# - CPU / memory / pids limits from config.resources.
# - Healthcheck from config.health.
# - Restart policy from config.restart (default: unless-stopped).
# - Labels record deployment name and image tag for `nelly ps`.
# - Pass --image <tag> to run a specific tag (used by rollback).
set -euo pipefail

DEPLOY_DIR="$1"; shift
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

IMAGE_OVERRIDE=""
while (( $# > 0 )); do
    case "$1" in
        --image) IMAGE_OVERRIDE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

CONFIG="$DEPLOY_DIR/def/config.json"
ENV_FILE="$DEPLOY_DIR/def/.env"
LOG_FILE="$DEPLOY_DIR/logs/run.log"
mkdir -p "$(dirname "$LOG_FILE")" "$DEPLOY_DIR/logs/cron"
exec > >(log_to "$LOG_FILE") 2>&1

require_cmd jq docker
validate_config "$DEPLOY_DIR"

CONTAINER_NAME="$(jqget "$CONFIG" '.container_name')"
DEPLOY_NAME="$(basename "$DEPLOY_DIR")"

if [[ -n "$IMAGE_OVERRIDE" ]]; then
    IMAGE_TAG="$IMAGE_OVERRIDE"
else
    IMAGE_TAG="$(cat "$DEPLOY_DIR/def/last_image.txt" 2>/dev/null || echo "$(jqget "$CONFIG" '.image_name'):latest")"
fi

# ---- network ---------------------------------------------------------------

NETWORK="$(jqget "$CONFIG"   '.network.network_name' '')"
SUBNET="$(jqget "$CONFIG"    '.network.subnet' '')"
GATEWAY="$(jqget "$CONFIG"   '.network.gateway' '')"
STATIC_IP="$(jqget "$CONFIG" '.network.static_ip' '')"

# ---- assemble docker run as an argv array (NO eval) ------------------------

declare -a DOCKER_ARGS=(
    run -d
    --name "$CONTAINER_NAME"
    --label "nelly.deployment=$DEPLOY_NAME"
    --label "nelly.image=$IMAGE_TAG"
    --label "nelly.managed=true"
)

# restart policy
RESTART="$(jqget "$CONFIG" '.restart' 'unless-stopped')"
DOCKER_ARGS+=(--restart "$RESTART")

# resources
CPUS="$(jqget "$CONFIG" '.resources.cpus' '')"
MEM="$(jqget "$CONFIG"  '.resources.memory' '')"
MEM_SWAP="$(jqget "$CONFIG" '.resources.memory_swap' '')"
PIDS="$(jqget "$CONFIG" '.resources.pids_limit' '')"
[[ -n "$CPUS" ]]     && DOCKER_ARGS+=(--cpus      "$CPUS")
[[ -n "$MEM"  ]]     && DOCKER_ARGS+=(--memory    "$MEM")
[[ -n "$MEM_SWAP" ]] && DOCKER_ARGS+=(--memory-swap "$MEM_SWAP")
[[ -n "$PIDS" ]]     && DOCKER_ARGS+=(--pids-limit "$PIDS")

# healthcheck
HC_CMD="$(jqget "$CONFIG"      '.health.cmd' '')"
HC_INTERVAL="$(jqget "$CONFIG" '.health.interval' '30s')"
HC_TIMEOUT="$(jqget "$CONFIG"  '.health.timeout'  '5s')"
HC_RETRIES="$(jqget "$CONFIG"  '.health.retries'  '3')"
if [[ -n "$HC_CMD" ]]; then
    DOCKER_ARGS+=(
        --health-cmd      "$HC_CMD"
        --health-interval "$HC_INTERVAL"
        --health-timeout  "$HC_TIMEOUT"
        --health-retries  "$HC_RETRIES"
    )
else
    # Default healthcheck: cron must be running.
    DOCKER_ARGS+=(
        --health-cmd      "pgrep -x cron >/dev/null || exit 1"
        --health-interval "$HC_INTERVAL"
        --health-timeout  "$HC_TIMEOUT"
        --health-retries  "$HC_RETRIES"
    )
fi

# network
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

# ports (validated by config.sh; format HOST:CONTAINER or IP:HOST:CONTAINER)
mapfile -t PORTS < <(jq -r '.network.ports[]?' "$CONFIG")
for p in "${PORTS[@]}"; do
    DOCKER_ARGS+=(-p "$p")
done

# secrets
if [[ -f "$ENV_FILE" ]]; then
    DOCKER_ARGS+=(--env-file "$ENV_FILE")
else
    warn "no $ENV_FILE — apps will run without secrets"
fi

# volumes (cron output)
DOCKER_ARGS+=(-v "$DEPLOY_DIR/logs/cron:/var/log/nelly")

# extra volumes from config.volumes[] — supports the standard "host:container[:ro]" form
mapfile -t VOLUMES < <(jq -r '.volumes[]?' "$CONFIG")
for v in "${VOLUMES[@]}"; do
    DOCKER_ARGS+=(-v "$v")
done

DOCKER_ARGS+=("$IMAGE_TAG")

# ---- replace existing container if present --------------------------------

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
