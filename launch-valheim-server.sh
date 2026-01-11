#!/bin/bash
#
# Linode Valheim Server Launcher
# Creates a Linode instance and deploys a Valheim server using Docker
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# CONFIGURATION - Load from .env file or use defaults
# =============================================================================

# Load .env file if it exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Linode Configuration (defaults if not set in .env)
LINODE_REGION="${LINODE_REGION:-us-ord}"
LINODE_TYPE="${LINODE_TYPE:-g8-dedicated-64-32}"
LINODE_IMAGE="${LINODE_IMAGE:-linode/ubuntu24.04}"
LINODE_LABEL="${LINODE_LABEL:-valheim-server}"
LINODE_ROOT_PASS="${LINODE_ROOT_PASS:-}"
LINODE_VOLUME_LABEL="${LINODE_VOLUME_LABEL:-valheim}"
LINODE_VOLUME_SIZE="${LINODE_VOLUME_SIZE:-100}"

# Valheim Server Configuration (defaults if not set in .env)
VALHEIM_SERVER_NAME="${VALHEIM_SERVER_NAME:-My Valheim Server}"
VALHEIM_WORLD_NAME="${VALHEIM_WORLD_NAME:-Dedicated}"
VALHEIM_SERVER_PASS="${VALHEIM_SERVER_PASS:-changeme123}"
VALHEIM_ADMIN_IDS="${VALHEIM_ADMIN_IDS:-}"
VALHEIM_SERVER_PORT="${VALHEIM_SERVER_PORT:-2456}"

# AWS Route 53 Configuration (optional - leave empty to skip DNS update)
AWS_ROUTE53_HOSTED_ZONE_ID="${AWS_ROUTE53_HOSTED_ZONE_ID:-}"
AWS_ROUTE53_RECORD_NAME="${AWS_ROUTE53_RECORD_NAME:-}"
AWS_ROUTE53_TTL="${AWS_ROUTE53_TTL:-300}"

# AWS Credentials (optional - uses AWS CLI default profile if not set)
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

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

    # Check AWS CLI if Route 53 is configured
    if [ -n "$AWS_ROUTE53_HOSTED_ZONE_ID" ] || [ -n "$AWS_ROUTE53_RECORD_NAME" ]; then
        if ! command -v aws &> /dev/null; then
            error "aws CLI is not installed but Route 53 is configured. Install it with: pip install awscli"
        fi

        if [ -z "$AWS_ROUTE53_HOSTED_ZONE_ID" ] || [ -z "$AWS_ROUTE53_RECORD_NAME" ]; then
            error "Both AWS_ROUTE53_HOSTED_ZONE_ID and AWS_ROUTE53_RECORD_NAME must be set for Route 53 updates"
        fi

        # Check AWS credentials
        if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
            log "Using AWS credentials from environment variables"
            # Test credentials by calling AWS STS
            if ! AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" aws sts get-caller-identity &> /dev/null; then
                error "AWS credentials are invalid. Please check AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
            fi
        elif [ -n "$AWS_ACCESS_KEY_ID" ] || [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
            error "Both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set together"
        else
            # Check if AWS CLI is configured with default profile
            if ! aws sts get-caller-identity &> /dev/null; then
                error "aws CLI is not configured. Run: aws configure OR set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
            fi
            log "Using AWS credentials from default profile"
        fi

        log "AWS CLI configured for Route 53 updates"
    fi

    log "All dependencies satisfied."
}

generate_password() {
    # Generate a secure random password
    openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 32
}

find_or_create_volume() {
    log "Checking for existing volume '$LINODE_VOLUME_LABEL'..."

    # Check if volume already exists
    VOLUME_DATA=$(linode-cli volumes list --json | jq -r ".[] | select(.label == \"$LINODE_VOLUME_LABEL\" and .region == \"$LINODE_REGION\")")

    if [ -n "$VOLUME_DATA" ]; then
        VOLUME_ID=$(echo "$VOLUME_DATA" | jq -r '.id')
        VOLUME_SIZE_ACTUAL=$(echo "$VOLUME_DATA" | jq -r '.size')
        log "Found existing volume '$LINODE_VOLUME_LABEL' (ID: $VOLUME_ID, Size: ${VOLUME_SIZE_ACTUAL}GB)"

        # Check if volume is already attached
        LINODE_ID_ATTACHED=$(echo "$VOLUME_DATA" | jq -r '.linode_id')
        if [ "$LINODE_ID_ATTACHED" != "null" ] && [ -n "$LINODE_ID_ATTACHED" ]; then
            error "Volume '$LINODE_VOLUME_LABEL' is already attached to Linode ID: $LINODE_ID_ATTACHED. Please detach it first."
        fi
    else
        log "Creating new volume '$LINODE_VOLUME_LABEL' (${LINODE_VOLUME_SIZE}GB) in region $LINODE_REGION..."
        VOLUME_CREATE_DATA=$(linode-cli volumes create \
            --label "$LINODE_VOLUME_LABEL" \
            --region "$LINODE_REGION" \
            --size "$LINODE_VOLUME_SIZE" \
            --json)

        VOLUME_ID=$(echo "$VOLUME_CREATE_DATA" | jq -r '.[0].id')
        log "Volume created with ID: $VOLUME_ID"
    fi
}

attach_volume() {
    local linode_id=$1
    local volume_id=$2

    log "Attaching volume '$LINODE_VOLUME_LABEL' to Linode..."

    linode-cli volumes attach "$volume_id" --linode_id "$linode_id" &> /dev/null

    log "Volume attached successfully!"
}

update_route53_record() {
    local ip_address=$1

    # Skip if Route 53 is not configured
    if [ -z "$AWS_ROUTE53_HOSTED_ZONE_ID" ] || [ -z "$AWS_ROUTE53_RECORD_NAME" ]; then
        log "Route 53 not configured, skipping DNS update"
        return 0
    fi

    log "Updating Route 53 record '$AWS_ROUTE53_RECORD_NAME' to point to $ip_address..."

    # Create JSON for the change batch
    local change_batch=$(cat <<EOF
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$AWS_ROUTE53_RECORD_NAME",
        "Type": "A",
        "TTL": $AWS_ROUTE53_TTL,
        "ResourceRecords": [
          {
            "Value": "$ip_address"
          }
        ]
      }
    }
  ]
}
EOF
)

    # Update the Route 53 record with optional credentials
    local aws_cmd="aws route53 change-resource-record-sets \
        --hosted-zone-id \"$AWS_ROUTE53_HOSTED_ZONE_ID\" \
        --change-batch '$change_batch' \
        --output json"

    # Run with explicit credentials if provided, otherwise use default profile
    if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
        CHANGE_INFO=$(AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" eval "$aws_cmd" 2>&1)
    else
        CHANGE_INFO=$(eval "$aws_cmd" 2>&1)
    fi

    if [ $? -eq 0 ]; then
        CHANGE_ID=$(echo "$CHANGE_INFO" | jq -r '.ChangeInfo.Id')
        log "Route 53 record updated successfully (Change ID: $CHANGE_ID)"
        log "DNS record '$AWS_ROUTE53_RECORD_NAME' now points to $ip_address"
    else
        log "Warning: Failed to update Route 53 record. Error: $CHANGE_INFO"
        log "You may need to update DNS manually."
    fi
}

create_cloud_init() {
    # Generate cloud-init user data to set up Docker and Valheim
    cat <<CLOUD_INIT_EOF
#cloud-config
package_update: true
package_upgrade: true

packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - ufw

write_files:
  - path: /opt/valheim/docker-compose.yml
    content: |
      services:
        valheim-server:
          container_name: valheim-server
          image: ghcr.io/community-valheim-tools/valheim-server:sha-9220bdc
          network_mode: bridge
          cap_add:
            - sys_nice
          restart: unless-stopped
          volumes:
            - /data/valheim-server/config/:/config/
            - /data/valheim-server/data/:/opt/valheim/
          ports:
            - ${VALHEIM_SERVER_PORT}:${VALHEIM_SERVER_PORT}/udp
            - $((VALHEIM_SERVER_PORT + 1)):$((VALHEIM_SERVER_PORT + 1))/udp
            - $((VALHEIM_SERVER_PORT + 2)):$((VALHEIM_SERVER_PORT + 2))/udp
          env_file:
            - ./valheim.env
          environment:
            - SERVER_PORT=${VALHEIM_SERVER_PORT}
            - SERVER_ARGS=-crossplay
            - SERVER_PUBLIC=false
            - BEPINEX=true
            - BEPINEXCFG_Logging_DOT_Console_Enabled=true

  - path: /opt/valheim/valheim.env
    content: |
      SERVER_NAME=${VALHEIM_SERVER_NAME}
      WORLD_NAME=${VALHEIM_WORLD_NAME}
      SERVER_PASS=${VALHEIM_SERVER_PASS}
      ADMINLIST_IDS=${VALHEIM_ADMIN_IDS}

runcmd:
  # Configure firewall
  - ufw allow 22/tcp
  - ufw allow ${VALHEIM_SERVER_PORT}:$((VALHEIM_SERVER_PORT + 2))/udp
  - ufw --force enable

  # LongView
  - curl -s https://lv.linode.com/3E593845-3223-4C80-AC8B33EE001F0085 | sudo bash

  # Install Docker
  - curl -fsSL https://get.docker.com | sh

  # Mount Linode volume
  - |
    # Wait for volume device to be available
    for i in {1..30}; do
      if [ -b /dev/sdc ]; then
        break
      fi
      sleep 2
    done

    # Check if volume is formatted
    if ! blkid /dev/sdc; then
      echo "Formatting volume..."
      mkfs.ext4 /dev/sdc
    fi

    # Create mount point and mount
    mkdir -p /data/valheim-server
    mount /dev/sdc /data/valheim-server

    # Add to fstab for persistence
    echo "/dev/sdc /data/valheim-server ext4 defaults,nofail 0 2" >> /etc/fstab

  # Create data directories
  - mkdir -p /data/valheim-server/config
  - mkdir -p /data/valheim-server/data

  # Start Valheim server
  - cd /opt/valheim && docker compose up -d

  # Log completion
  - echo "Valheim server setup complete" > /var/log/valheim-setup-complete
CLOUD_INIT_EOF
}

create_linode() {
    log "Creating Linode instance..."

    # Generate root password if not set
    if [ -z "$LINODE_ROOT_PASS" ]; then
        LINODE_ROOT_PASS=$(generate_password)
        log "Generated root password: $LINODE_ROOT_PASS"
    fi

    # Create cloud-init metadata
    CLOUD_INIT_DATA=$(create_cloud_init)

    # Create the Linode with cloud-init
    LINODE_DATA=$(linode-cli linodes create \
        --region "$LINODE_REGION" \
        --type "$LINODE_TYPE" \
        --image "$LINODE_IMAGE" \
        --label "$LINODE_LABEL" \
        --root_pass "$LINODE_ROOT_PASS" \
        --metadata.user_data "$(echo "$CLOUD_INIT_DATA" | base64 -w0)" \
        --json)

    LINODE_ID=$(echo "$LINODE_DATA" | jq -r '.[0].id')
    LINODE_IP=$(echo "$LINODE_DATA" | jq -r '.[0].ipv4[0]')

    log "Linode created with ID: $LINODE_ID"
    log "Linode IP Address: $LINODE_IP"
}

wait_for_running() {
    local linode_id=$1
    log "Waiting for Linode to be running..."

    while true; do
        STATUS=$(linode-cli linodes view "$linode_id" --json | jq -r '.[0].status')

        if [ "$STATUS" = "running" ]; then
            log "Linode is now running!"
            break
        fi

        log "Current status: $STATUS - waiting..."

        sleep 10
    done
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo "=============================================="
    echo "  Linode Valheim Server Launcher (Docker)"
    echo "=============================================="
    echo ""

    # Validate configuration
    if [ ${#VALHEIM_SERVER_PASS} -lt 5 ]; then
        error "Server password must be at least 5 characters"
    fi

    check_dependencies

    log "Configuration:"
    log "  Region: $LINODE_REGION"
    log "  Instance Type: $LINODE_TYPE"
    log "  Volume: $LINODE_VOLUME_LABEL (${LINODE_VOLUME_SIZE}GB)"
    if [ -n "$AWS_ROUTE53_RECORD_NAME" ]; then
        log "  DNS: $AWS_ROUTE53_RECORD_NAME (Route 53)"
    fi
    log "  Server Name: $VALHEIM_SERVER_NAME"
    log "  World Name: $VALHEIM_WORLD_NAME"
    log "  Port: $VALHEIM_SERVER_PORT"
    echo ""

    discord "🚀 Starting deployment of Valheim server in Linode region '$LINODE_REGION'..."

    # Find or create volume
    find_or_create_volume

    # Create Linode
    create_linode

    discord "✅ Linode instance created (ID: $LINODE_ID, IP: $LINODE_IP). Attaching volume and finalizing setup..."

    # Wait for it to be running
    wait_for_running "$LINODE_ID"

    # Attach volume
    attach_volume "$LINODE_ID" "$VOLUME_ID"

    discord "🔧 Volume attached. Valheim server is being set up. This may take a few minutes..."

    echo "Updating DNS if configured..."
    # Update Route 53 DNS record if configured
    update_route53_record "$LINODE_IP"

    # Wait for setup to complete (wait until connection to server is possible)
    discord "🎉 Valheim server deployment initiated! Waiting for world to become ready..."

    # NOTE: UDP ports may not respond to ping, so we just wait a fixed time here
    sleep 300

    discord "🗺️ $VALHEIM_WORLD_NAME is ready! Connect to $AWS_ROUTE53_RECORD_NAME:$VALHEIM_SERVER_PORT or $LINODE_IP:$VALHEIM_SERVER_PORT."

    echo ""
    echo "=============================================="
    echo "  Valheim Server Deployed Successfully!"
    echo "=============================================="
    echo ""
    echo "  Server Details:"
    echo "  ---------------"
    echo "  Linode ID:     $LINODE_ID"
    echo "  IP Address:    $LINODE_IP"
    echo "  Root Password: $LINODE_ROOT_PASS"
    echo "  Volume ID:     $VOLUME_ID"
    echo "  Volume:        $LINODE_VOLUME_LABEL (${LINODE_VOLUME_SIZE}GB)"
    echo ""
    echo "  Valheim Server:"
    echo "  ---------------"
    echo "  Server Name:   $VALHEIM_SERVER_NAME"
    echo "  World Name:    $VALHEIM_WORLD_NAME"
    echo "  Password:      $VALHEIM_SERVER_PASS"
    if [ -n "$AWS_ROUTE53_RECORD_NAME" ]; then
        echo "  Connect To:    $AWS_ROUTE53_RECORD_NAME:$VALHEIM_SERVER_PORT"
        echo "  (or via IP):   $LINODE_IP:$VALHEIM_SERVER_PORT"
    else
        echo "  Connect To:    $LINODE_IP:$VALHEIM_SERVER_PORT"
    fi
    echo ""
    echo "  NOTE: Docker setup takes 3-5 minutes to complete."
    echo "  You can monitor progress by SSH-ing in and running:"
    echo "    ssh root@$LINODE_IP"
    echo "    docker logs -f valheim-server"
    echo ""
    echo "  To check if setup is complete:"
    echo "    ssh root@$LINODE_IP 'cat /var/log/valheim-setup-complete'"
    echo ""
    echo "  To check container status:"
    echo "    ssh root@$LINODE_IP 'docker ps'"
    echo ""
    echo "=============================================="

    # Save connection info to file
    {
        cat << EOF
Valheim Server Information
==========================
Created: $(date)

Linode:
  ID: $LINODE_ID
  Label: $LINODE_LABEL
  IP: $LINODE_IP
  Root Password: $LINODE_ROOT_PASS
  Region: $LINODE_REGION

Volume:
  ID: $VOLUME_ID
  Label: $LINODE_VOLUME_LABEL
  Size: ${LINODE_VOLUME_SIZE}GB
  Mount: /data/valheim-server
EOF

        if [ -n "$AWS_ROUTE53_RECORD_NAME" ]; then
            cat << EOF

DNS:
  Record: $AWS_ROUTE53_RECORD_NAME
  Points To: $LINODE_IP
  Hosted Zone: $AWS_ROUTE53_HOSTED_ZONE_ID
EOF
        fi

        cat << EOF

Valheim:
  Server Name: $VALHEIM_SERVER_NAME
  World Name: $VALHEIM_WORLD_NAME
  Password: $VALHEIM_SERVER_PASS
EOF

        if [ -n "$AWS_ROUTE53_RECORD_NAME" ]; then
            echo "  Connect To: $AWS_ROUTE53_RECORD_NAME:$VALHEIM_SERVER_PORT"
            echo "  (or via IP): $LINODE_IP:$VALHEIM_SERVER_PORT"
        else
            echo "  Connect To: $LINODE_IP:$VALHEIM_SERVER_PORT"
        fi

        cat << EOF

SSH Access: ssh root@$LINODE_IP
Docker Logs: docker logs -f valheim-server
EOF
    } > "$SCRIPT_DIR/valheim-server-info.txt"

    log "Server info saved to valheim-server-info.txt"
}

# Run main function
main "$@"
