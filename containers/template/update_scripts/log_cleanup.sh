#!/bin/bash

echo "Starting log cleanup..."

# Paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
LOG_DIR="$SCRIPT_DIR/../logs"

# Log file
LOG_FILE="$LOG_DIR/log_cleanup.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Logging function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1" | tee -a "$LOG_FILE"
}

# Cleanup logic
log "Cleaning up old logs..."
find "$LOG_DIR" -type f -name "*.log" -mtime +7 -exec rm -f {} \; || {
    log "Error: Failed to clean up logs."
    exit 1
}

log "Log cleanup completed."
echo "SUCCESS"
