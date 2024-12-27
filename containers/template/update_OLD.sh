#!/bin/bash

# Determine absolute paths
SCRIPT_DIR="$(dirname "$(realpath "$0")")"     # Absolute path of the script directory
PROJECT_NAME="$(basename "$SCRIPT_DIR")"        # Get the project folder name
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"  # Two levels up to reach Nelly
NELLY_CONFIG="$ROOT_DIR/Nelly_config.json"      # Path to Nelly_config.json in the root directory
TARGET_CONFIG="$SCRIPT_DIR/config.json"         # Path to config.json in the script directory
REPO_DIR="$SCRIPT_DIR/app"                     # Path to the local Git repo directory

# Docker image and container names based on the project name
IMAGE_NAME="${PROJECT_NAME}_docker_image"
CONTAINER_NAME="${PROJECT_NAME}_docker_container"

# Prompt: Update config.json from Nelly_config.json
read -p "Do you want to update config.json with values from Nelly_config.json? (y/n): " update_config
if [[ $update_config == [yY] ]]; then
    # Check if Nelly_config.json exists
    if [ ! -f "$NELLY_CONFIG" ]; then
        echo "Error: Nelly_config.json not found at $NELLY_CONFIG"
        exit 1
    fi

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        echo "jq is required but not installed. Installing it..."
        sudo apt-get update && sudo apt-get install -y jq
    fi

    # Read the entire contents of Nelly_config.json as a JSON object
    new_nelly_config=$(jq '. | {nelly_config: .}' "$NELLY_CONFIG")

    # Update the nelly_config key in config.json
    jq --argjson newConfig "$new_nelly_config" '.nelly_config = $newConfig.nelly_config' "$TARGET_CONFIG" > "$TARGET_CONFIG.tmp"
    mv "$TARGET_CONFIG.tmp" "$TARGET_CONFIG"
    echo "Updated nelly_config in $TARGET_CONFIG with values from $NELLY_CONFIG"
else
    echo "Skipping config.json update."
fi

# Load configurations from config.json
if ! command -v jq &> /dev/null; then
    echo "jq is required but not installed. Installing it..."
    sudo apt-get update && sudo apt-get install -y jq
fi

# Read configurations from config.json
GIT_REPO_URL=$(jq -r '.git_url' "$TARGET_CONFIG")
BRANCH=$(jq -r '.branch' "$TARGET_CONFIG")
STATIC_IP=$(jq -r '.static_ip' "$TARGET_CONFIG")
ADDITIONAL_DOCKER_RUN_OPTIONS=$(jq -r '.docker_run_options' "$TARGET_CONFIG")
PACKAGES=$(jq -r '.packages[]' "$TARGET_CONFIG")  # Read the list of packages

# Read network_name from nelly_config
NETWORK_NAME=$(jq -r '.nelly_config.network_name' "$TARGET_CONFIG")


echo "GIT_REPO_URL is set to: $GIT_REPO_URL"
echo "BRANCH is set to: $BRANCH"
echo "REPO_DIR is set to: $REPO_DIR"


# Prompt: Update Git repository
read -p "Do you want to update the Git repository in the app folder? (y/n): " update_repo
if [[ $update_repo == [yY] ]]; then
    # Check if GIT_REPO_URL and BRANCH are valid
    if [[ -z "$GIT_REPO_URL" || -z "$BRANCH" ]]; then
        echo "Error: git_url or branch is not set in $TARGET_CONFIG"
        exit 1
    fi

    # Clone or pull the repository
    if [ -d "$REPO_DIR" ]; then
        if [ -d "$REPO_DIR/.git" ]; then
            echo "Pulling latest changes from $GIT_REPO_URL (branch: $BRANCH) into $REPO_DIR..."
            cd "$REPO_DIR" && git pull origin "$BRANCH"
        else
            echo "$REPO_DIR exists but is not a Git repository. Reinitializing..."
            rm -rf "$REPO_DIR"
            git clone -b "$BRANCH" "$GIT_REPO_URL" "$REPO_DIR"
        fi
    else
        echo "Cloning repository from $GIT_REPO_URL (branch: $BRANCH) into $REPO_DIR..."
        git clone -b "$BRANCH" "$GIT_REPO_URL" "$REPO_DIR"
    fi

    echo "Git repository update completed successfully."

    # Replace the content of config.json in the app folder with the app_config from TARGET_CONFIG
    echo "Updating config.json in $REPO_DIR with app_config from $TARGET_CONFIG..."
    if [[ -f "$TARGET_CONFIG" ]]; then
        # Use jq to extract app_config and write to config.json
        jq '.app_config' "$TARGET_CONFIG" > "$REPO_DIR/config.json"
        echo "config.json has been updated."
    else
        echo "Error: $TARGET_CONFIG does not exist."
        exit 1
    fi
else
    echo "Skipping Git repository update."
fi


# Prompt: Build Docker image and manage container
read -p "Do you want to build the Docker image and manage the container? (y/n): " manage_docker
if [[ $manage_docker == [yY] ]]; then
    # Navigate to the project directory (assumed to be the script directory)
    cd "$SCRIPT_DIR" || { echo "Failed to change directory to $SCRIPT_DIR"; exit 1; }

    # Create a temporary Dockerfile
    echo "Creating temporary Dockerfile..."
    cp Dockerfile Dockerfile.temp

    # Replace $PROJECT_NAME with the actual project name in Dockerfile.temp
    sed -i "s/\$PROJECT_NAME/$PROJECT_NAME/g" Dockerfile.temp

    # Read packages from config.json and modify temporary Dockerfile
    if [ -n "$PACKAGES" ]; then
        echo "Adding package installation to temporary Dockerfile..."
        # Build a list of packages to install
        PACKAGE_LIST=""
        for pkg in $PACKAGES; do
            PACKAGE_LIST+="$pkg "
        done

        # Insert the package installation command after FROM line
        sed -i '/^FROM/a\
RUN apt-get update && apt-get install -y '"$PACKAGE_LIST"' && rm -rf /var/lib/apt/lists/*
' Dockerfile.temp
    fi

    # Stop and remove existing container if it exists
    RUNNING_CONTAINER=$(docker ps -q --filter "name=$CONTAINER_NAME")
    if [ ! -z "$RUNNING_CONTAINER" ]; then
        echo "Stopping running container $CONTAINER_NAME..."
        docker stop "$CONTAINER_NAME"
    fi

    EXISTING_CONTAINER=$(docker ps -a -q --filter "name=$CONTAINER_NAME")
    if [ ! -z "$EXISTING_CONTAINER" ]; then
        echo "Removing existing container $CONTAINER_NAME..."
        docker rm "$CONTAINER_NAME"
    fi

    # Remove existing image if it exists
    EXISTING_IMAGE=$(docker images -q "$IMAGE_NAME")
    if [ ! -z "$EXISTING_IMAGE" ]; then
        echo "Removing existing image $IMAGE_NAME..."
        docker rmi "$IMAGE_NAME"
    fi

    # Build the new Docker image using the temporary Dockerfile
    echo "Building Docker image $IMAGE_NAME..."
    if ! docker build --no-cache -t "$IMAGE_NAME" -f Dockerfile.temp .; then
        echo "Error: Failed to build the Docker image. Exiting..."
        rm Dockerfile.temp
        exit 1
    fi

    # Remove the temporary Dockerfile
    rm Dockerfile.temp

    # Ensure the logs directory exists
    mkdir -p "$SCRIPT_DIR/logs"

    # Run the Docker container
    echo "Running Docker container $CONTAINER_NAME..."
    DOCKER_RUN_CMD="docker run -d --name \"$CONTAINER_NAME\""
    if [ -n "$NETWORK_NAME" ] && [ -n "$STATIC_IP" ]; then
        DOCKER_RUN_CMD+=" --network \"$NETWORK_NAME\" --ip \"$STATIC_IP\""
    fi
    if [ -n "$ADDITIONAL_DOCKER_RUN_OPTIONS" ] && [ "$ADDITIONAL_DOCKER_RUN_OPTIONS" != "null" ]; then
        DOCKER_RUN_CMD+=" $ADDITIONAL_DOCKER_RUN_OPTIONS"
    fi

    # Add the volume mapping for the logs folder
    DOCKER_RUN_CMD+=" -v \"$SCRIPT_DIR/logs:/home/logs\""

    DOCKER_RUN_CMD+=" \"$IMAGE_NAME\""

    # Execute the Docker run command
    if ! eval $DOCKER_RUN_CMD; then
        echo "Error: Failed to run the Docker container. Exiting..."
        exit 1
    fi

    echo "Docker container $CONTAINER_NAME is now running."

    # Optionally open a shell in the container
    read -p "Do you want to open a shell in the container now? (y/n): " open_shell
    if [[ $open_shell == [yY] ]]; then
        docker exec -it "$CONTAINER_NAME" /bin/bash
        echo "You have exited the shell. The container is still running in the background."
    else
        echo "Skipping shell access. The container is still running in the background."
    fi
else
    echo "Skipping Docker image build and container management."
fi

echo "Process complete."
