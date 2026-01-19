# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project provisions Valheim game servers on Linode cloud infrastructure using Docker. The main script creates a Linode instance and deploys a containerized Valheim dedicated server via cloud-init.

## Key Commands

```bash
# Launch a new Valheim server (requires linode-cli configured)
./launch-valheim-server.sh

# Stop and delete the running Valheim server (preserves volume)
./stop-valheim-server.sh

# Prerequisites
pip install linode-cli
linode-cli configure

# Optional: For clean server shutdown (recommended)
# Ubuntu/Debian:
sudo apt-get install sshpass
# macOS:
brew install hudochenkov/sshpass/sshpass

# Optional: For Route 53 DNS updates
pip install awscli
aws configure
```

## Architecture

- **launch-valheim-server.sh**: Main entry point that:
  - Creates or finds a Linode Block Storage volume named 'valheim' (100GB default)
  - Creates a Linode instance in the configured region (default: us-ord/Chicago)
  - Attaches the volume to the instance for persistent data storage
  - Updates Route 53 DNS record (optional) to point to the new server IP
  - Uses cloud-init to bootstrap Docker and deploy the Valheim container
  - Uses `ghcr.io/community-valheim-tools/valheim-server` Docker image
  - Outputs connection info to `valheim-server-info.txt`

- **stop-valheim-server.sh**: Shutdown script that:
  - Reads Linode label from `valheim-server-info.txt` (or uses configured default)
  - Searches for the Linode instance by label (robust against outdated info files)
  - Verifies the Linode instance exists and retrieves current details
  - SSHs into the server to cleanly stop Docker container and unmount volume
  - Detaches the Block Storage volume (preserving all game data)
  - Gracefully shuts down the Linode instance
  - Deletes the Linode instance to stop billing
  - Archives the server info file with timestamp
  - Prompts for confirmation before proceeding
  - **Requires `sshpass`** for automated SSH (optional but recommended)

- **Server Configuration**: Copy `.env.example` to `.env` and customize:
  - `LINODE_REGION`, `LINODE_TYPE` - Infrastructure settings
  - `LINODE_VOLUME_LABEL`, `LINODE_VOLUME_SIZE`, `LINODE_VOLUME_MOUNT_POINT` - Block storage settings (volume persists between deployments)
  - `AWS_ROUTE53_HOSTED_ZONE_ID`, `AWS_ROUTE53_RECORD_NAME` - Optional DNS configuration
  - `VALHEIM_SERVER_NAME`, `VALHEIM_WORLD_NAME`, `VALHEIM_SERVER_PASS` - Game server settings
  - `VALHEIM_ADMIN_IDS` - Steam IDs for admin access

- **DNS Management**: Optionally configure Route 53 to automatically update a DNS record:
  - Set `AWS_ROUTE53_HOSTED_ZONE_ID` to your Route 53 hosted zone ID
  - Set `AWS_ROUTE53_RECORD_NAME` to your desired domain (e.g., `valheim.example.com`)
  - The script will create or update an A record pointing to the new Linode IP
  - Connect using the domain name instead of remembering IP addresses
  - **Authentication options:**
    - Use AWS CLI default profile (run `aws configure`)
    - OR set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in `.env` file
    - Useful for CI/CD or when you don't want to use the default AWS profile

## Remote Server Management

After deployment, the Valheim server runs on the Linode instance:
- Data persisted at `/data/valheim-server/` on the remote host (mounted from Linode Block Storage volume)
- The volume persists even if the Linode instance is destroyed - rerunning the script will reattach the same volume
- Docker compose config at `/opt/valheim/docker-compose.yml`
- Check status: `ssh root@<IP> 'docker ps'`
- View logs: `ssh root@<IP> 'docker logs -f valheim-server'`

## Server Lifecycle

The typical workflow for managing the Valheim server:

1. **Launch**: Run `./launch-valheim-server.sh` to create a new Linode and volume
2. **Play**: Players connect and game data is saved to the persistent volume
3. **Stop**: Run `./stop-valheim-server.sh` to delete the Linode (stops billing)
4. **Restart**: Run `./launch-valheim-server.sh` again - it will reuse the existing volume with all saved data

This allows you to only pay for compute when actively playing, while keeping your game world persistent.
