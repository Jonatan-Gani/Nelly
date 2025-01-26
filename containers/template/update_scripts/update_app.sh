#!/bin/bash

echo "Starting Application Update..."

# ----------------------------------------------------------------------------------
# 1. Basic Setup
# ----------------------------------------------------------------------------------

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
DEF_DIR="$SCRIPT_DIR/../def"
APPS_DIR="$SCRIPT_DIR/../apps"
TEMP_DIR="$SCRIPT_DIR/../temp_repo"
LOG_DIR="$SCRIPT_DIR/../logs"
CONFIG_FILE="$DEF_DIR/config.json"
ENV_FILE_LOCAL="$DEF_DIR/.env"   # Local secrets file containing ENV_* variables
LOG_FILE="$LOG_DIR/update_app.log"

# Ensure necessary directories exist
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Logging function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# ----------------------------------------------------------------------------------
# 2. Ensure Dependencies
# ----------------------------------------------------------------------------------

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    log "jq is required but not installed. Installing jq..."
    sudo apt-get update && sudo apt-get install -y jq || {
        log "Error: Failed to install jq."
        exit 1
    }
fi

# Verify config.json exists
if [ ! -f "$CONFIG_FILE" ]; then
    log "Error: config.json not found at $CONFIG_FILE."
    exit 1
fi

# ----------------------------------------------------------------------------------
# 3. Load Local .env (Secrets) Into Shell Environment
# ----------------------------------------------------------------------------------
# If you want your .env lines like ENV_DB_HOST_tamar_template="1.2.3.4" to be recognized,
# we source them so they become shell variables (i.e., $ENV_DB_HOST_tamar_template).

if [ -f "$ENV_FILE_LOCAL" ]; then
    log "Loading local .env file ($ENV_FILE_LOCAL) into environment..."
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE_LOCAL"
    set +a
else
    log "Warning: Local .env file not found at $ENV_FILE_LOCAL. Any ENV_* references will be empty."
fi

# ----------------------------------------------------------------------------------
# 4. Extract Apps Array from config.json
# ----------------------------------------------------------------------------------

APPS=$(jq -c '.apps[]' "$CONFIG_FILE")
if [ -z "$APPS" ]; then
    log "Error: No apps defined in the configuration file."
    exit 1
fi

# ----------------------------------------------------------------------------------
# 5. Process Each App
# ----------------------------------------------------------------------------------
log "Processing applications defined in the configuration..."
for app in $APPS; do
    APP_NAME=$(echo "$app" | jq -r '.app_name // empty')
    GIT_REPO_URL=$(echo "$app" | jq -r '.git_url // empty')
    BRANCH=$(echo "$app" | jq -r '.branch // empty')

    if [ -z "$APP_NAME" ] || [ -z "$GIT_REPO_URL" ] || [ -z "$BRANCH" ]; then
        log "Error: Missing required fields (app_name, git_url, branch) for one of the apps."
        continue
    fi

    APP_FOLDER="$APPS_DIR/$APP_NAME"

    # ------------------------------------------------------------------------------
    # Step 5A: (Optional) Update Repository Content
    # ------------------------------------------------------------------------------
    read -p "Do you want to update the repository content for app ($APP_NAME)? (y/n): " update_repo
    if [[ "$update_repo" =~ ^[yY] ]]; then
        log "Fetching repository content for app ($APP_NAME) from $GIT_REPO_URL (branch: $BRANCH)..."

        # Clean the app-specific directory (excluding the possibility of hidden files)
        if [ -d "$APP_FOLDER" ]; then
            log "Cleaning up existing folder for $APP_NAME..."
            rm -rf "$APP_FOLDER"/*
        else
            mkdir -p "$APP_FOLDER"
        fi

        # Create a temporary directory for cloning
        if [ -d "$TEMP_DIR" ]; then
            log "Removing existing temporary directory..."
            rm -rf "$TEMP_DIR"
        fi
        mkdir -p "$TEMP_DIR"

        # Clone the repository into the temporary directory
        log "Cloning repository for $APP_NAME..."
        git clone --branch "$BRANCH" --depth 1 "$GIT_REPO_URL" "$TEMP_DIR" || {
            log "Error: Failed to clone repository for $APP_NAME."
            rm -rf "$TEMP_DIR"
            continue
        }

        # Copy repository content to the app folder (excluding .git metadata)
        log "Copying repository content to app folder for $APP_NAME..."
        rsync -av --exclude='.git' "$TEMP_DIR/" "$APP_FOLDER/" || {
            log "Error: Failed to copy repository content for $APP_NAME."
            rm -rf "$TEMP_DIR"
            continue
        }

        # Clean up the temporary directory
        log "Cleaning up temporary directory for $APP_NAME..."
        rm -rf "$TEMP_DIR"

        log "Repository content for $APP_NAME updated successfully."
    else
        log "Skipped repository content update for $APP_NAME."
    fi

    # ------------------------------------------------------------------------------
    # Step 5B: (Optional) Update Environment Variables for This App
    # ------------------------------------------------------------------------------
    # ------------------------------------------------------------------------------
    # Step 5B: Update Environment Variables for This App
    # ------------------------------------------------------------------------------
    read -p "Do you want to update the environment variables for app ($APP_NAME)? (y/n): " update_env
    if [[ "$update_env" =~ ^[yY] ]]; then
        log "Updating environment variables (.env) for $APP_NAME..."

        # The .env data is defined under `env` in config.json
        ENV_KEYS=$(echo "$app" | jq -r '.env | keys[]' 2>/dev/null)
        if [ -z "$ENV_KEYS" ]; then
            log "No 'env' block found for $APP_NAME in config.json. Skipping env creation."
            continue
        fi

        # Path to the .env file in the app folder
        APP_ENV_FILE="$APP_FOLDER/.env"

        # Remove any old .env file
        if [ -f "$APP_ENV_FILE" ]; then
            rm -f "$APP_ENV_FILE"
            log "Removed old .env file for $APP_NAME."
        fi

        touch "$APP_ENV_FILE"

        # For each key in the app's env block
        for key in $ENV_KEYS; do
            raw_value=$(echo "$app" | jq -r ".env.\"$key\"")

            # If raw_value starts with "ENV_", treat it as a reference to a shell var
            if [[ "$raw_value" == ENV_* ]]; then
                # real variable name in the shell environment
                real_env_name="$raw_value"
                # expand it (this is the actual secret or value from def/.env or the system)
                real_val="${!real_env_name}"

                # If empty, log a warning
                if [ -z "$real_val" ]; then
                    log "WARNING: Environment variable '$real_env_name' not set for $APP_NAME ($key)."
                    # You can choose to write an empty value or skip it
                    echo "$key=\"\"" >> "$APP_ENV_FILE"
                else
                    echo "$key=\"$real_val\"" >> "$APP_ENV_FILE"
                fi
            else
                # Otherwise, treat it as a literal and quote it
                echo "$key=\"$raw_value\"" >> "$APP_ENV_FILE"
            fi
        done

        log ".env file for $APP_NAME created/updated successfully."
    else
        log "Skipped environment variable update for $APP_NAME."
    fi


done

# ----------------------------------------------------------------------------------
# Final confirmation
# ----------------------------------------------------------------------------------
log "All application updates completed."
echo "SUCCESS"
