#!/bin/bash
#
# Linode Valheim Server Shutdown Script
# Shuts down and deletes the Linode instance while preserving the volume
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFO_FILE="$SCRIPT_DIR/valheim-server-info.txt"

# Load .env file if it exists (for LINODE_LABEL default)
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Default Linode label if not in .env
LINODE_LABEL_DEFAULT="${LINODE_LABEL:-valheim-server}"

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

discord() {
    log "$1"

    ./discord-notify.sh "$1"
}

error() {
    echo "[ERROR] $1" >&2
    exit 1
}

check_dependencies() {
    log "Checking dependencies..."

    if ! command -v linode-cli &> /dev/null; then
        error "linode-cli is not installed. Install it with: pip install linode-cli"
    fi

    if ! command -v jq &> /dev/null; then
        error "jq is not installed. Install it with your package manager."
    fi

    # Check if linode-cli is configured
    if ! linode-cli regions list &> /dev/null; then
        error "linode-cli is not configured. Run: linode-cli configure"
    fi

    # Check for sshpass (optional but recommended)
    if ! command -v sshpass &> /dev/null; then
        log "Warning: sshpass not found - remote cleanup will be skipped"
        log "For proper cleanup, install with:"
        log "  Ubuntu/Debian: sudo apt-get install sshpass"
        log "  macOS: brew install hudochenkov/sshpass/sshpass"
    fi

    log "All required dependencies satisfied."
}

parse_info_file() {
    if [ ! -f "$INFO_FILE" ]; then
        error "Server info file not found: $INFO_FILE"
    fi

    log "Reading server information from $INFO_FILE..."

    # Extract Linode label from info file (primary method)
    LINODE_LABEL=$(grep -A 5 "^Linode:" "$INFO_FILE" | grep "Label:" | awk '{print $2}')

    # Fallback to default if not found in file
    if [ -z "$LINODE_LABEL" ]; then
        log "Warning: Linode label not found in info file, using default: $LINODE_LABEL_DEFAULT"
        LINODE_LABEL="$LINODE_LABEL_DEFAULT"
    else
        log "Found Linode label: $LINODE_LABEL"
    fi

    # Extract other information (may not be available yet if searching by label)
    LINODE_IP=$(grep "IP:" "$INFO_FILE" | head -1 | awk '{print $2}')
    LINODE_ROOT_PASS=$(grep "Root Password:" "$INFO_FILE" | awk '{print $3}')
    VOLUME_ID=$(grep -A 10 "^Volume:" "$INFO_FILE" | grep "ID:" | awk '{print $2}')
    VOLUME_LABEL=$(grep "Label:" "$INFO_FILE" | tail -1 | awk '{print $2}')

    if [ -n "$LINODE_IP" ]; then
        log "IP Address: $LINODE_IP"
    fi
    if [ -n "$VOLUME_ID" ]; then
        log "Volume ID: $VOLUME_ID (Label: $VOLUME_LABEL)"
    fi
}

verify_linode_exists() {
    log "Searching for Linode with label '$LINODE_LABEL'..."

    # List all Linodes and filter by label
    ALL_LINODES=$(linode-cli linodes list --json 2>&1)

    if [ $? -ne 0 ]; then
        error "Failed to list Linodes. Is linode-cli configured correctly?"
    fi

    # Find Linode by label using jq
    LINODE_DATA=$(echo "$ALL_LINODES" | jq -r ".[] | select(.label == \"$LINODE_LABEL\")")

    if [ -z "$LINODE_DATA" ]; then
        error "No Linode found with label '$LINODE_LABEL'. It may have already been deleted."
    fi

    # Extract Linode details
    LINODE_ID=$(echo "$LINODE_DATA" | jq -r '.id')
    LINODE_STATUS=$(echo "$LINODE_DATA" | jq -r '.status')

    # Update IP if not already set from info file
    if [ -z "$LINODE_IP" ]; then
        LINODE_IP=$(echo "$LINODE_DATA" | jq -r '.ipv4[0]')
        log "Retrieved IP Address: $LINODE_IP"
    fi

    log "Found Linode '$LINODE_LABEL' (ID: $LINODE_ID)"
    log "Status: $LINODE_STATUS"
}

cleanup_server() {
    # Skip if server is not running
    if [ "$LINODE_STATUS" != "running" ]; then
        log "Linode is not running, skipping server cleanup"
        return 0
    fi

    # Skip if we don't have IP or password
    if [ -z "$LINODE_IP" ] || [ -z "$LINODE_ROOT_PASS" ]; then
        log "Warning: Missing IP or root password, skipping server cleanup"
        return 0
    fi

    log "Connecting to server to cleanly stop services..."

    # Disable strict host key checking for this session
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

    # Create a temporary script to run on the remote server
    local cleanup_commands=$(cat <<'REMOTE_SCRIPT'
set -e

echo "Stopping Docker container..."
if docker ps -q --filter "name=valheim-server" | grep -q .; then
    docker stop valheim-server || echo "Warning: Failed to stop container gracefully"
    # Give it a moment to stop
    sleep 2
fi

echo "Unmounting volume..."
if mountpoint -q /data/valheim-server; then
    umount /data/valheim-server || echo "Warning: Failed to unmount volume"
else
    echo "Volume not mounted"
fi

echo "Cleanup complete"
REMOTE_SCRIPT
)

    # Execute the cleanup commands via SSH using sshpass
    if command -v sshpass &> /dev/null; then
        log "Using sshpass for authentication..."
        echo "$cleanup_commands" | sshpass -p "$LINODE_ROOT_PASS" ssh $SSH_OPTS root@"$LINODE_IP" 'bash -s' 2>&1 | while IFS= read -r line; do
            log "  [remote] $line"
        done

        if [ ${PIPESTATUS[1]} -eq 0 ]; then
            log "Server cleanup completed successfully"
        else
            log "Warning: Server cleanup encountered issues, continuing anyway..."
        fi
    else
        log "Warning: sshpass not installed, skipping server cleanup"
        log "Install sshpass with: sudo apt-get install sshpass (Debian/Ubuntu) or brew install hudochenkov/sshpass/sshpass (macOS)"
    fi
}

detach_volume() {
    if [ -z "$VOLUME_ID" ]; then
        log "No volume information found, skipping detach"
        return 0
    fi

    log "Checking if volume needs to be detached..."

    # Check if volume is attached
    VOLUME_DATA=$(linode-cli volumes view "$VOLUME_ID" --json 2>&1)

    if [ $? -ne 0 ]; then
        log "Warning: Could not find volume $VOLUME_ID"
        return 0
    fi

    ATTACHED_TO=$(echo "$VOLUME_DATA" | jq -r '.[0].linode_id')

    if [ "$ATTACHED_TO" = "null" ] || [ -z "$ATTACHED_TO" ]; then
        log "Volume is already detached"
    else
        log "Detaching volume '$VOLUME_LABEL' from Linode..."
        linode-cli volumes detach "$VOLUME_ID" &> /dev/null
        log "Volume detached successfully"

        # Wait a moment for detachment to complete
        sleep 60
    fi
}

shutdown_linode() {
    log "Shutting down Linode $LINODE_ID..."

    # First try to power off gracefully if it's running
    if [ "$LINODE_STATUS" = "running" ]; then
        log "Powering off Linode..."

        linode-cli linodes shutdown "$LINODE_ID"

        # Wait for shutdown
        log "Waiting for Linode to shut down..."
        for i in {1..30}; do
            STATUS=$(linode-cli linodes view "$LINODE_ID" --json | jq -r '.[0].status')
            if [ "$STATUS" = "offline" ]; then
                log "Linode powered off"
                break
            fi
            sleep 2
        done
    fi
}

delete_linode() {
    log "Deleting Linode $LINODE_ID..."

    linode-cli linodes delete "$LINODE_ID" 2>&1

    if [ $? -eq 0 ]; then
        log "Linode deleted successfully"
    else
        error "Failed to delete Linode"
    fi
}

cleanup_info_file() {
    log "Archiving server info file..."

    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    ARCHIVE_FILE="$SCRIPT_DIR/valheim-server-info-${TIMESTAMP}.txt"

    mv "$INFO_FILE" "$ARCHIVE_FILE"
    log "Server info archived to: $ARCHIVE_FILE"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo "=============================================="
    echo "  Linode Valheim Server Shutdown"
    echo "=============================================="
    echo ""

    check_dependencies
    parse_info_file
    verify_linode_exists

    discord "⚠️ Initiating shutdown of Valheim server Linode instance (ID: $LINODE_ID)..."

    echo ""
    echo "WARNING: This will shut down and DELETE the Linode instance."
    if [ -n "$VOLUME_LABEL" ]; then
        echo "The volume '$VOLUME_LABEL' will be PRESERVED with all game data."
    fi
    echo ""
    echo "Linode Details:"
    echo "  ID: $LINODE_ID"
    echo "  Label: $LINODE_LABEL"
    echo "  Status: $LINODE_STATUS"
    if [ -n "$LINODE_IP" ]; then
        echo "  IP: $LINODE_IP"
    fi
    echo ""

    log "Starting shutdown process..."

    # Clean up server services first
    cleanup_server

    # Detach volume (before deletion)
    detach_volume

    discord "🔧 Volume detached. Proceeding to shut down and delete Linode instance (ID: $LINODE_ID)..."

    # Shutdown the Linode
    shutdown_linode

    # Delete the Linode
    delete_linode

    discord "✅ Valheim server Linode instance (ID: $LINODE_ID) has been shut down and deleted. Volume '$VOLUME_LABEL' preserved."

    # Archive the info file
    cleanup_info_file

    echo ""
    echo "=============================================="
    echo "  Valheim Server Shutdown Complete"
    echo "=============================================="
    echo ""
    if [ -n "$VOLUME_LABEL" ]; then
        echo "  Volume '$VOLUME_LABEL' (ID: $VOLUME_ID) has been preserved."
        echo "  Run ./launch-valheim-server.sh to create a new server"
        echo "  and automatically reattach the volume with your saved data."
    fi
    echo ""
    echo "=============================================="
}

# Run main function
main "$@"
