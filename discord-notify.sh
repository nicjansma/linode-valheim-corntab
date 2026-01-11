#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env file if it exists
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

DISCORD_WEBHOOK="$DISCORD_WEBHOOK_URL"
DISCORD_MESSAGE="$1"

curl -sfSL \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$DISCORD_USERNAME\",\"content\":\"$DISCORD_MESSAGE\"}" \
    "$DISCORD_WEBHOOK"

