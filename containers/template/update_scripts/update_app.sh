#!/bin/bash

echo "Starting Application Update..."

# Paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
DEF_DIR="$SCRIPT_DIR/../def"
APP_DIR="$SCRIPT_DIR/../app"
TEMP_DIR="$SCRIPT_DIR/../temp_repo"
LOG_DIR="$SCRIPT_DIR/../logs"
CONFIG_FILE="$DEF_DIR/config.json"
LOG_FILE="$LOG_DIR/update_app.log"

# Ensure necessary directories exist
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Logging function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    log "jq is required but not installed. Installing jq..."
    sudo apt-get update && sudo apt-get install -y jq || {
        log "Error: Failed to install jq."
        exit 1
    }
fi

# Verify critical paths
if [ ! -f "$CONFIG_FILE" ]; then
    log "Error: config.json not found at $CONFIG_FILE."
    exit 1
fi
if [ ! -d "$APP_DIR" ]; then
    log "Error: App directory not found at $APP_DIR."
    exit 1
fi

# Extract values from the config structure
APP_NAME=$(jq -r '.container_config.apps[0].app_name // empty' "$CONFIG_FILE")
GIT_REPO_URL=$(jq -r '.container_config.apps[0].git_url // empty' "$CONFIG_FILE")
BRANCH=$(jq -r '.container_config.apps[0].branch // empty' "$CONFIG_FILE")

if [ -z "$APP_NAME" ] || [ -z "$GIT_REPO_URL" ] || [ -z "$BRANCH" ]; then
    log "Error: Missing required fields (app_name, git_url, branch) in container_config.apps."
    exit 1
fi

# Step 1: Ask user about fetching repository content
read -p "Do you want to update the repository content in the app folder? (y/n): " update_repo
if [[ "$update_repo" =~ ^[yY] ]]; then
    log "Fetching repository content for app ($APP_NAME) from $GIT_REPO_URL (branch: $BRANCH)..."

    # Clean the app directory
    if [ -d "$APP_DIR" ]; then
        log "Cleaning up existing app directory..."
        rm -rf "$APP_DIR/*"
    else
        mkdir -p "$APP_DIR"
    fi

    # Create a temporary directory for cloning
    if [ -d "$TEMP_DIR" ]; then
        log "Removing existing temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
    mkdir -p "$TEMP_DIR"

    # Clone the repository into the temporary directory
    log "Cloning repository..."
    git clone --branch "$BRANCH" --depth 1 "$GIT_REPO_URL" "$TEMP_DIR" || {
        log "Error: Failed to clone repository."
        rm -rf "$TEMP_DIR"
        exit 1
    }

    # Copy repository content to the app folder (excluding .git metadata)
    log "Copying repository content to app folder..."
    rsync -av --exclude='.git' "$TEMP_DIR/" "$APP_DIR/" || {
        log "Error: Failed to copy repository content."
        rm -rf "$TEMP_DIR"
        exit 1
    }

    # Clean up the temporary directory
    log "Cleaning up temporary directory..."
    rm -rf "$TEMP_DIR"

    log "Repository content updated successfully."
else
    log "Skipped repository content update."
fi

# Final confirmation
log "Application content update process SUCCESS."