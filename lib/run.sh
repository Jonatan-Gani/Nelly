#!/usr/bin/env bash
# lib/run.sh — (re)start a deployment's container.
#
# Features:
#   - argv-array `docker run` (no eval); no string interpolation of config.
#   - Secrets mounted at runtime via --env-file; never baked into the image.
#   - Resource limits (cpus / memory / memory_swap / pids_limit).
#   - Healthcheck (defaults to "cron is running").
#   - Restart policy (default unless-stopped).
#   - Labels record nelly.deployment / nelly.image / nelly.tags so `nelly ps`
#     and external tools can filter cleanly.
#   - Multi-network attachment + DNS aliases + hostname + arbitrary labels +
#     DNS servers + extra /etc/hosts entries.
#   - --image <tag>      run a specific image (used by rollback)
#   - --wait-healthy [N] wait up to N seconds for healthcheck to pass
#   - --auto-rollback    on wait-healthy failure, switch back to previous tag
set -euo pipefail

DEPLOY_DIR="$1"; shift
LIB="$(dirname "$(realpath "$0")")"
# shellcheck source=common.sh
source "$LIB/common.sh"
# shellcheck source=config.sh
source "$LIB/config.sh"

IMAGE_OVERRIDE=""
WAIT_HEALTHY=0
AUTO_ROLLBACK=0
while (( $# > 0 )); do
    case "$1" in
        --image)         IMAGE_OVERRIDE="$2"; shift 2 ;;
        --wait-healthy)  WAIT_HEALTHY="${2:-60}"; shift 2 ;;
        --auto-rollback) AUTO_ROLLBACK=1; shift ;;
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
    IMAGE_TAG="$(cat "$DEPLOY_DIR/def/last_image.txt" 2>/dev/null \
                  || echo "$(jqget "$CONFIG" '.image_name'):latest")"
fi

# -------- network -----------------------------------------------------------

NETWORK="$(jqget "$CONFIG"   '.network.network_name' '')"
SUBNET="$(jqget "$CONFIG"    '.network.subnet' '')"
GATEWAY="$(jqget "$CONFIG"   '.network.gateway' '')"
STATIC_IP="$(jqget "$CONFIG" '.network.static_ip' '')"
HOSTNAME_OPT="$(jqget "$CONFIG" '.network.hostname' '')"

mapfile -t EXTRA_NETS < <(jq -r '.network.extra_networks[]?' "$CONFIG")
mapfile -t ALIASES    < <(jq -r '.network.aliases[]?'        "$CONFIG")
mapfile -t DNS        < <(jq -r '.network.dns[]?'            "$CONFIG")
mapfile -t HOSTS      < <(jq -r '.network.extra_hosts[]?'    "$CONFIG")

# -------- assemble docker run as argv array (NO eval) ----------------------

# Build the tag list. nelly.tags is comma-separated for easy grep'ability.
TAGS_JOINED="$(jq -r '(.tags // []) | join(",")' "$CONFIG")"

declare -a DOCKER_ARGS=(
    run -d
    --name "$CONTAINER_NAME"
    --label "nelly.deployment=$DEPLOY_NAME"
    --label "nelly.image=$IMAGE_TAG"
    --label "nelly.managed=true"
    --label "nelly.tags=$TAGS_JOINED"
)

# Custom labels (e.g. for reverse proxies like Traefik / nginx-proxy)
while IFS=$'\t' read -r k v; do
    [[ -z "$k" ]] && continue
    DOCKER_ARGS+=(--label "$k=$v")
done < <(jq -r '(.network.labels // {}) | to_entries[] | "\(.key)\t\(.value)"' "$CONFIG")

# Hostname inside the container
[[ -n "$HOSTNAME_OPT" ]] && DOCKER_ARGS+=(--hostname "$HOSTNAME_OPT")

# DNS servers + extra /etc/hosts entries
for d in "${DNS[@]}"; do
    DOCKER_ARGS+=(--dns "$d")
done
for h in "${HOSTS[@]}"; do
    DOCKER_ARGS+=(--add-host "$h")
done

# Restart policy
RESTART="$(jqget "$CONFIG" '.restart' 'unless-stopped')"
DOCKER_ARGS+=(--restart "$RESTART")

# Resources
CPUS="$(jqget "$CONFIG"      '.resources.cpus' '')"
MEM="$(jqget "$CONFIG"       '.resources.memory' '')"
MEM_SWAP="$(jqget "$CONFIG"  '.resources.memory_swap' '')"
PIDS="$(jqget "$CONFIG"      '.resources.pids_limit' '')"
[[ -n "$CPUS" ]]     && DOCKER_ARGS+=(--cpus       "$CPUS")
[[ -n "$MEM"  ]]     && DOCKER_ARGS+=(--memory     "$MEM")
[[ -n "$MEM_SWAP" ]] && DOCKER_ARGS+=(--memory-swap "$MEM_SWAP")
[[ -n "$PIDS" ]]     && DOCKER_ARGS+=(--pids-limit "$PIDS")

# Healthcheck
HC_CMD="$(jqget "$CONFIG"      '.health.cmd' '')"
HC_INTERVAL="$(jqget "$CONFIG" '.health.interval' '30s')"
HC_TIMEOUT="$(jqget "$CONFIG"  '.health.timeout'  '5s')"
HC_RETRIES="$(jqget "$CONFIG"  '.health.retries'  '3')"
[[ -z "$HC_CMD" ]] && HC_CMD="pgrep -x cron >/dev/null || exit 1"
DOCKER_ARGS+=(
    --health-cmd      "$HC_CMD"
    --health-interval "$HC_INTERVAL"
    --health-timeout  "$HC_TIMEOUT"
    --health-retries  "$HC_RETRIES"
)

# Primary network
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
    for a in "${ALIASES[@]}"; do
        DOCKER_ARGS+=(--network-alias "$a")
    done
fi

# Ports
mapfile -t PORTS < <(jq -r '.network.ports[]?' "$CONFIG")
for p in "${PORTS[@]}"; do
    DOCKER_ARGS+=(-p "$p")
done

# Deployment-wide secrets:
#   --env-file mounts them as env vars at container start (so `docker exec`
#   and PID 1 see them), AND
#   we ALSO bind-mount the file as /etc/nelly/global.env so `nelly-run`
#   can source it for cron-fired jobs (cron clears its env on dispatch,
#   so --env-file alone is not enough).
if [[ -f "$ENV_FILE" ]]; then
    DOCKER_ARGS+=(--env-file "$ENV_FILE")
    DOCKER_ARGS+=(-v "$ENV_FILE:/etc/nelly/global.env:ro")
fi

# Per-app secrets — bind-mounted read-only into the container at
# /etc/nelly/secrets/. `nelly-run` sources the matching app's file at
# invocation time, so cron jobs for different apps in the same container
# do NOT share each other's env vars at runtime.
APP_SECRETS_DIR="$DEPLOY_DIR/def/secrets"
if [[ -d "$APP_SECRETS_DIR" ]]; then
    DOCKER_ARGS+=(-v "$APP_SECRETS_DIR:/etc/nelly/secrets:ro")
fi

if [[ ! -f "$ENV_FILE" && ! -d "$APP_SECRETS_DIR" ]]; then
    warn "no secrets configured ($ENV_FILE not present, no def/secrets/) — apps will run with no env"
fi

# Volumes — default cron-logs mount, then any extras from config.
DOCKER_ARGS+=(-v "$DEPLOY_DIR/logs/cron:/var/log/nelly")
mapfile -t VOLUMES < <(jq -r '.volumes[]?' "$CONFIG")
for v in "${VOLUMES[@]}"; do
    DOCKER_ARGS+=(-v "$v")
done

DOCKER_ARGS+=("$IMAGE_TAG")

# -------- replace existing container if present ----------------------------

PREVIOUS_TAG=""
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    PREVIOUS_TAG="$(docker inspect -f '{{index .Config.Labels "nelly.image"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
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

# Attach to any extra networks AFTER the container is created.
for n in "${EXTRA_NETS[@]}"; do
    info "connecting $CONTAINER_NAME to extra network: $n"
    if ! docker network inspect "$n" >/dev/null 2>&1; then
        info "creating extra network $n"
        docker network create "$n"
    fi
    docker network connect "$n" "$CONTAINER_NAME"
done

# -------- optional wait-for-healthy + auto-rollback ------------------------

if (( WAIT_HEALTHY > 0 )); then
    info "waiting up to ${WAIT_HEALTHY}s for healthcheck…"
    deadline=$(( $(date +%s) + WAIT_HEALTHY ))
    ok=0
    while (( $(date +%s) < deadline )); do
        state="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
        running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
        if [[ "$running" != "true" ]]; then
            warn "container exited during health wait"
            break
        fi
        if [[ "$state" == "healthy" ]]; then
            ok=1; break
        fi
        sleep 2
    done

    if (( ok )); then
        info "container is healthy"
    else
        err "container did not become healthy within ${WAIT_HEALTHY}s"
        if (( AUTO_ROLLBACK )) && [[ -n "$PREVIOUS_TAG" && "$PREVIOUS_TAG" != "$IMAGE_TAG" ]]; then
            warn "auto-rolling back to $PREVIOUS_TAG"
            docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
            docker rm   "$CONTAINER_NAME" >/dev/null 2>&1 || true
            exec "$LIB/run.sh" "$DEPLOY_DIR" --image "$PREVIOUS_TAG"
        fi
        exit 1
    fi
fi

info "container $CONTAINER_NAME is up"
