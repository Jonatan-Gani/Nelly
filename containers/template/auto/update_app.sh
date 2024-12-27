#!/bin/bash

# Paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
APP_DIR="$SCRIPT_DIR/../app"
CONFIG_FILE="$SCRIPT_DIR/../def/config.json"

# Log file
LOG_FILE="$SCRIPT_DIR/../logs/update_app.log"
mkdir -p "$(dirname "$LOG_FILE")"
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

# Read configuration
if [ ! -f "$CONFIG_FILE" ]; then
    log "Error: config.json not found at $CONFIG_FILE."
    exit 1
fi

GIT_REPO_URL=$(jq -r '.git_url' "$CONFIG_FILE")
BRANCH=$(jq -r '.branch' "$CONFIG_FILE")
APP_CONFIG=$(jq -r '.app_config' "$CONFIG_FILE")

if [ -z "$GIT_REPO_URL" ] || [ -z "$BRANCH" ]; then
    log "Error: git_url or branch is missing in config.json."
    exit 1
fi

# Step 1: Ask user about fetching repository content
read -p "Do you want to update the repository content in the app folder? (y/n): " update_repo
if [[ "$update_repo" =~ ^[yY] ]]; then
    log "Fetching repository content from $GIT_REPO_URL (branch: $BRANCH)..."
    
    # Clean the app directory
    if [ -d "$APP_DIR" ]; then
        log "Cleaning up existing app directory..."
        rm -rf "$APP_DIR/*"
    else
        mkdir -p "$APP_DIR"
    fi

    # Fetch repository content
    ZIP_URL="${GIT_REPO_URL%.git}/archive/$BRANCH.zip"
    wget -O repo.zip "$ZIP_URL" || {
        log "Error: Failed to download repository archive."
        exit 1
    }
    unzip -o repo.zip -d "$APP_DIR" || {
        log "Error: Failed to extract repository archive."
        rm repo.zip
        exit 1
    }
    rm repo.zip
    log "Repository content updated successfully."
else
    log "Skipped repository content update."
fi

# Step 2: Ask user about app-specific config.json update
read -p "Do you want to update the app-specific config.json in the app folder? (y/n): " update_config
if [[ "$update_config" =~ ^[yY] ]]; then
    if [ -n "$APP_CONFIG" ]; then
        log "Updating app-specific config.json in $APP_DIR..."
        echo "$APP_CONFIG" > "$APP_DIR/config.json" || {
            log "Error: Failed to update app-specific config.json."
            exit 1
        }
        log "App-specific config.json updated successfully."
    else
        log "No app-specific config.json provided in config.json. Skipping."
    fi
else
    log "Skipped app-specific config.json update."
fi

# Final confirmation
log "Application content update process completed."
echo "SUCCESS"
