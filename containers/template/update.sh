#!/bin/bash

echo "Starting Update Process..."

# Paths
MAIN_DIR="$(dirname "$(realpath "$0")")"
SCRIPTS_DIR="$MAIN_DIR/update_scripts"
CONFIG_FILE="$MAIN_DIR/def/config.json"
LOG_FILE="$MAIN_DIR/logs/update_logs.log"

# Ensure log file exists
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Log function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# Ensure all scripts in the update_scripts directory are executable
ensure_permissions() {
    log "Checking permissions for scripts in $SCRIPTS_DIR..."
    for script in "$SCRIPTS_DIR"/*.sh; do
        if [ ! -x "$script" ]; then
            chmod +x "$script"
            log "Updated execute permission for $script."
        fi
    done
}

# Run a script and handle confirmation
run_script() {
    local script_path=$1
    local script_name=$(basename "$script_path")
    
    log "Starting $script_name..."

    # Check if the script exists
    if [ ! -f "$script_path" ]; then
        log "Error: Script $script_name does not exist at $script_path."
        return 1
    fi
    log "Checked if the script exists..."

    # Run the script and forward logs
    bash "$script_path" 2>&1 | tee -a "$LOG_FILE"
    exit_code=${PIPESTATUS[0]}
    
    # Check the exit code
    if [ $exit_code -eq 0 ]; then
        log "$script_name completed successfully."
        return 0
    else
        log "$script_name FAILED. Exit code: $exit_code."
        return 1
    fi
}

# Validate config.json exists
if [ ! -f "$CONFIG_FILE" ]; then
    log "Error: Configuration file ($CONFIG_FILE) not found."
    exit 1
fi

# Load container name and app details from config.json
CONTAINER_NAME=$(jq -r '.container_name // "default_container"' "$CONFIG_FILE")
IMAGE_NAME=$(jq -r '.image_name // "default_image"' "$CONFIG_FILE")
NETWORK_NAME=$(jq -r '.network.network_name // "default_network"' "$CONFIG_FILE")

if [ -z "$CONTAINER_NAME" ] || [ -z "$IMAGE_NAME" ] || [ -z "$NETWORK_NAME" ]; then
    log "Error: Missing required container configuration (container_name, image_name, network_name)."
    exit 1
fi

log "Using configuration:"
log "   - Container Name:   $CONTAINER_NAME"
log "   - Image Name:       $IMAGE_NAME"
log "   - Network Name:     $NETWORK_NAME"

# Start update process
log "Starting update process for container: $CONTAINER_NAME"

# Ensure scripts have the correct permissions
ensure_permissions

# Step 1: Sync Configurations
run_script "$SCRIPTS_DIR/config_mng.sh" || { log "Update process terminated at config_mng.sh"; exit 1; }

# Step 2: Update Application Code
run_script "$SCRIPTS_DIR/update_app.sh" || { log "Update process terminated at update_app.sh"; exit 1; }

# Step 3: Build Docker Image
run_script "$SCRIPTS_DIR/build_docker.sh" || { log "Update process terminated at build_docker.sh"; exit 1; }

# Step 4: Manage Docker Container
run_script "$SCRIPTS_DIR/manage_docker.sh" || { log "Update process terminated at manage_docker.sh"; exit 1; }

# Step 5: Cleanup Logs
run_script "$SCRIPTS_DIR/log_cleanup.sh" || { log "Update process terminated at log_cleanup.sh"; exit 1; }

# End update process
log "Update process completed successfully for container: $CONTAINER_NAME"
