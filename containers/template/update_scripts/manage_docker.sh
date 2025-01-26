#!/bin/bash

echo "Starting Docker container management..."

# Paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/../def/config.json"

# Log file
LOG_FILE="$SCRIPT_DIR/../logs/manage_docker.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Logging function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# Read configuration
if [ ! -f "$CONFIG_FILE" ]; then
    log "Error: config.json not found at $CONFIG_FILE."
    exit 1
fi

# Extract configuration values
CONTAINER_NAME=$(jq -r '.container_name // "default_container"' "$CONFIG_FILE")
IMAGE_NAME=$(jq -r '.image_name // "default_image"' "$CONFIG_FILE")
NETWORK_NAME=$(jq -r '.network.network_name // "default_network"' "$CONFIG_FILE")
STATIC_IP=$(jq -r '.network.static_ip // empty' "$CONFIG_FILE")
DOCKER_RUN_OPTIONS=$(jq -r '.network.docker_run_options // empty' "$CONFIG_FILE")

# Step 1: Check if the container already exists
if docker ps -a --format "{{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
    log "A container with the name ($CONTAINER_NAME) already exists."
    read -p "The container '$CONTAINER_NAME' already exists. Do you want to stop and remove it? (y/n): " remove_container
    if [[ "$remove_container" != "y" && "$remove_container" != "Y" ]]; then
        log "Skipping container deployment as the existing container was not removed."
        echo "Aborted"
        exit 0
    fi

    log "Stopping and removing existing container ($CONTAINER_NAME)..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
fi

# Step 2: Check if the network exists
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    log "Network ($NETWORK_NAME) not found. Creating it..."
    if ! docker network create --driver bridge --subnet=192.168.20.0/24 --gateway=192.168.20.1 "$NETWORK_NAME"; then
        log "Error: Failed to create network ($NETWORK_NAME)."
        exit 1
    fi
    log "Network ($NETWORK_NAME) created successfully."
else
    log "Network ($NETWORK_NAME) already exists."
fi

# Step 3: Run Docker container
log "Running Docker container ($CONTAINER_NAME)..."
DOCKER_RUN_CMD="docker run -d --name \"$CONTAINER_NAME\""
[ -n "$NETWORK_NAME" ] && DOCKER_RUN_CMD+=" --network \"$NETWORK_NAME\""
[ -n "$STATIC_IP" ] && DOCKER_RUN_CMD+=" --ip \"$STATIC_IP\""
[ -n "$DOCKER_RUN_OPTIONS" ] && DOCKER_RUN_CMD+=" $DOCKER_RUN_OPTIONS"
DOCKER_RUN_CMD+=" -v \"$SCRIPT_DIR/../logs:/home/logs\" \"$IMAGE_NAME\""

if ! eval $DOCKER_RUN_CMD; then
    log "Error: Failed to run the Docker container."
    exit 1
fi

log "Docker container ($CONTAINER_NAME) is now running."
echo "SUCCESS"
