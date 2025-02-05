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

# Extract values from the new config structure
IMAGE_NAME=$(jq -r '.image_name // "default_image"' "$CONFIG_FILE")
PROJECT_NAME=$(jq -r '.container_name // "default_container"' "$CONFIG_FILE")
PACKAGES=$(jq -r '.packages[]' "$CONFIG_FILE")

# Check if the image name already exists
if docker images --format "{{.Repository}}" | grep -q "^$IMAGE_NAME$"; then
    log "Docker image ($IMAGE_NAME) already exists."
    read -p "The image '$IMAGE_NAME' already exists. Do you want to overwrite it? (y/n): " overwrite
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
        log "Build process aborted by user."
        echo "Aborted"
        exit 0
    fi
    log "Proceeding to overwrite the existing image ($IMAGE_NAME)."
fi

# Step 1: Prepare temporary Dockerfile
TEMP_DOCKERFILE="$SCRIPT_DIR/Dockerfile.temp"
log "Creating temporary Dockerfile..."
cp "$SCRIPT_DIR/../def/Dockerfile" "$TEMP_DOCKERFILE"

# Define the PROJECT_NAME in the Dockerfile
log "Setting up PROJECT_NAME in Dockerfile..."
sed -i "/^FROM/a ARG PROJECT_NAME=$PROJECT_NAME\nENV PROJECT_NAME=\$PROJECT_NAME" "$TEMP_DOCKERFILE"

# Insert placeholder for per-app requirements installation
log "Adding placeholder for per-app requirements installation to Dockerfile..."
sed -i "/^WORKDIR/a # PLACEHOLDER: APP REQUIREMENTS INSTALLATION" "$TEMP_DOCKERFILE"

# Process each app directory and add a RUN command for its requirements
log "Adding per-app requirements installation commands to Dockerfile..."
APPS_DIR="$SCRIPT_DIR/../apps"
for app in "$APPS_DIR"/*; do
    if [ -d "$app" ] && [ -f "$app/requirements.txt" ]; then
        APP_NAME=$(basename "$app")
        log "Adding requirements installation for app: $APP_NAME"
        sed -i "/# PLACEHOLDER: APP REQUIREMENTS INSTALLATION/a RUN pip install -r /home/apps/$APP_NAME/requirements.txt" "$TEMP_DOCKERFILE"
    fi
done

# Add package installation to Dockerfile
if [ -n "$PACKAGES" ]; then
    log "Adding package installation to Dockerfile..."
    PACKAGE_LIST=$(echo "$PACKAGES" | tr '\n' ' ')
    sed -i "/^FROM/a RUN apt-get update && apt-get install -y $PACKAGE_LIST && rm -rf /var/lib/apt/lists/*" "$TEMP_DOCKERFILE"
fi

# Step 2: Build Docker image
log "Building Docker image ($IMAGE_NAME) with PROJECT_NAME=$PROJECT_NAME..."
if ! docker build --no-cache --build-arg PROJECT_NAME="$PROJECT_NAME" -t "$IMAGE_NAME" -f "$TEMP_DOCKERFILE" "$SCRIPT_DIR/.."; then
    log "Error: Failed to build the Docker image."
    rm -f "$TEMP_DOCKERFILE"
    exit 1
fi

# Clean up the temporary Dockerfile
rm -f "$TEMP_DOCKERFILE"

log "Docker image built successfully."
echo "SUCCESS"
