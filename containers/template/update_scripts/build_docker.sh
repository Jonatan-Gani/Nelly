#!/bin/bash

echo "Starting Docker image build..."

# Paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/../def/config.json"

# Log file
LOG_FILE="$SCRIPT_DIR/../logs/build_docker.log"
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
PACKAGES=$(jq -r '.container_config.packages[]' "$CONFIG_FILE")

# Step 1: Prepare temporary Dockerfile
TEMP_DOCKERFILE="$SCRIPT_DIR/Dockerfile.temp"
log "Creating temporary Dockerfile..."
cp "$SCRIPT_DIR/../def/Dockerfile" "$TEMP_DOCKERFILE"

# Add package installation to Dockerfile
if [ -n "$PACKAGES" ]; then
    log "Adding package installation to Dockerfile..."
    PACKAGE_LIST=$(echo "$PACKAGES" | tr '\n' ' ')
    sed -i "/^FROM/a RUN apt-get update && apt-get install -y $PACKAGE_LIST && rm -rf /var/lib/apt/lists/*" "$TEMP_DOCKERFILE"
fi

# Step 2: Build Docker image
log "Building Docker image ($IMAGE_NAME)..."
if ! docker build --no-cache -t "$IMAGE_NAME" -f "$TEMP_DOCKERFILE" "$SCRIPT_DIR/../app"; then
    log "Error: Failed to build the Docker image."
    rm -f "$TEMP_DOCKERFILE"
    exit 1
fi
rm -f "$TEMP_DOCKERFILE"

log "Docker image built successfully."
echo "SUCCESS"
