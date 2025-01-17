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

IMAGE_NAME=$(jq -r '.container_config.image_name // "default_image"' "$CONFIG_FILE")
CONTAINER_NAME=$(jq -r '.container_config.container_name // "default_container"' "$CONFIG_FILE")
NETWORK_NAME=$(jq -r '.container_config.network_name // empty' "$CONFIG_FILE")
STATIC_IP=$(jq -r '.container_config.static_ip // empty' "$CONFIG_FILE")
DOCKER_RUN_OPTIONS=$(jq -r '.container_config.docker_run_options // empty' "$CONFIG_FILE")

# Step 1: Stop and remove existing container
log "Stopping and removing existing container ($CONTAINER_NAME), if any..."
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Step 2: Run Docker container
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
