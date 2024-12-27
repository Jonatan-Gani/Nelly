#!/bin/bash

# Define paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
AUTO_DIR="$SCRIPT_DIR/auto"
LOG_FILE="$SCRIPT_DIR/logs/update_logs.log"

# Ensure log file exists
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Log function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# Run a script and handle confirmation
run_script() {
    local script_path=$1
    local script_name=$(basename "$script_path")
    
    log "Starting $script_name..."
    
    # Run the script and capture its output and exit code
    output=$("$script_path" 2>&1)
    exit_code=$?

    # Check for confirmation message
    if echo "$output" | grep -q "SUCCESS"; then
        log "$script_name completed successfully."
        return 0
    else
        log "$script_name FAILED. Exit code: $exit_code. Output: $output"
        return 1
    fi
}

# Start update process
log "Starting update process for container: $(basename "$SCRIPT_DIR")"

# Step 1: Sync Configurations
run_script "$AUTO_DIR/sync_config.sh" || { log "Update process terminated at sync_config.sh"; exit 1; }

# Step 2: Validate Configurations
run_script "$AUTO_DIR/validate_config.sh" || { log "Update process terminated at validate_config.sh"; exit 1; }

# Step 3: Update Application Code
run_script "$AUTO_DIR/update_app.sh" || { log "Update process terminated at update_app.sh"; exit 1; }

# Step 4: Build Docker Image
run_script "$AUTO_DIR/build_docker.sh" || { log "Update process terminated at build_docker.sh"; exit 1; }

# Step 5: Manage Docker Container
run_script "$AUTO_DIR/manage_docker.sh" || { log "Update process terminated at manage_docker.sh"; exit 1; }

# Step 6: Cleanup Logs
run_script "$AUTO_DIR/log_cleanup.sh" || { log "Update process terminated at log_cleanup.sh"; exit 1; }

# End update process
log "Update process completed successfully for container: $(basename "$SCRIPT_DIR")"
