#!/bin/bash

echo "Configuration management Started ..."

# Paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ROOT_DIR="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"  # Go three levels up to find the Nelly directory

NELLY_CONFIG="$ROOT_DIR/Nelly_config.json"
TARGET_CONFIG="$SCRIPT_DIR/../def/config.json"

# Log file
LOG_FILE="$SCRIPT_DIR/../logs/mng_config.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Logging function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# Check for jq
if ! command -v jq &> /dev/null; then
    log "jq is required but not installed. Installing jq..."
    sudo apt-get update && sudo apt-get install -y jq || {
        log "Error: Failed to install jq."
        exit 1
    }
fi

# Verify files exist
if [ ! -f "$NELLY_CONFIG" ]; then
    log "Error: Nelly_config.json not found at $NELLY_CONFIG."
    exit 1
fi

if [ ! -f "$TARGET_CONFIG" ]; then
    log "Error: Target config.json not found at $TARGET_CONFIG."
    exit 1
fi

# Step 1: Synchronize configurations
log "Synchronizing configurations from Nelly_config.json to config.json..."
jq --argjson nellyConfig "$(jq '.' "$NELLY_CONFIG")" '.nelly_config = $nellyConfig' "$TARGET_CONFIG" > "$TARGET_CONFIG.tmp" && mv "$TARGET_CONFIG.tmp" "$TARGET_CONFIG" || {
    log "Error: Failed to update config.json."
    exit 1
}
log "Configurations synchronized successfully."

# Final confirmation
log "Configuration management completed successfully."
echo "SUCCESS"
