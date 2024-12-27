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

# Step 1: Handle Git operations
if [ -d "$APP_DIR" ]; then
    if [ -d "$APP_DIR/.git" ]; then
        log "Pulling latest changes from $BRANCH branch in $GIT_REPO_URL..."
        cd "$APP_DIR" && git pull origin "$BRANCH" || {
            log "Error: Failed to pull latest changes."
            exit 1
        }
    else
        log "$APP_DIR exists but is not a Git repository. Reinitializing..."
        rm -rf "$APP_DIR"
        git clone -b "$BRANCH" "$GIT_REPO_URL" "$APP_DIR" || {
            log "Error: Failed to clone repository."
            exit 1
        }
    fi
else
    log "Cloning repository from $GIT_REPO_URL (branch: $BRANCH) into $APP_DIR..."
    git clone -b "$BRANCH" "$GIT_REPO_URL" "$APP_DIR" || {
        log "Error: Failed to clone repository."
        exit 1
    }
fi
log "Git operations completed successfully."

# Step 2: Update app-specific config.json
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

# Final confirmation
log "Application code updated successfully."
echo "SUCCESS"
