#!/bin/bash

# Paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # Go two levels up to find the Nelly directory
NELLY_CONFIG="$ROOT_DIR/Nelly_config.json"
TARGET_CONFIG="$SCRIPT_DIR/../def/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config_schema.json"     # Validation schema (should be predefined)

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

if [ ! -f "$SCHEMA_FILE" ]; then
    log "Error: Validation schema file not found at $SCHEMA_FILE."
    exit 1
fi

# Step 1: Synchronize configurations
log "Synchronizing configurations from Nelly_config.json to config.json..."
jq --argjson nellyConfig "$(jq '.' "$NELLY_CONFIG")" '.nelly_config = $nellyConfig' "$TARGET_CONFIG" > "$TARGET_CONFIG.tmp" && mv "$TARGET_CONFIG.tmp" "$TARGET_CONFIG" || {
    log "Error: Failed to update config.json."
    exit 1
}
log "Configurations synchronized successfully."

# Step 2: Validate config.json against schema
log "Validating config.json against schema..."
if ! jq -e "def validate(s): . as \$config | \$s as \$schema | . | \$schema | all(if type == \"object\" then \$config[$key] != null else true end); validate(\$schema)" --argjson s "$(cat "$SCHEMA_FILE")" "$TARGET_CONFIG" &>/dev/null; then
    log "Error: Validation of config.json failed."
    exit 1
fi
log "config.json validated successfully."

# Final confirmation
log "Configuration management completed successfully."
echo "SUCCESS"
