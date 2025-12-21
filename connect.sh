#!/bin/bash
# connect.sh - HTTP tunnel SSH connector
# Edit the CONFIG section below with your server details

set -e

# ============ CONFIG ============
SERVER_IP="YOUR_SERVER_IP"
SECRET_PATH="/YOUR_SECRET_PATH/"
LOCAL_PORT=2222
SSH_USER="root"

# Inline your private key here, or point to a file
PRIVATE_KEY_FILE=""  # e.g., ~/.ssh/id_tunnel
PRIVATE_KEY_INLINE=""  # paste key contents if not using file
# ================================

# Install dependencies if missing
install_deps() {
    if ! command -v htc &>/dev/null || ! command -v ssh &>/dev/null; then
        echo "[*] Installing httptunnel and ssh..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y httptunnel openssh-client
        elif command -v yum &>/dev/null; then
            yum install -y httptunnel openssh-clients
        elif command -v apk &>/dev/null; then
            apk add --no-cache httptunnel openssh-client
        else
            echo "[!] Can't install deps automatically. Install httptunnel and openssh-client manually."
            exit 1
        fi
    fi
}

# Setup SSH key
setup_key() {
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    
    if [[ -n "$PRIVATE_KEY_FILE" && -f "$PRIVATE_KEY_FILE" ]]; then
        KEY_PATH="$PRIVATE_KEY_FILE"
    elif [[ -n "$PRIVATE_KEY_INLINE" ]]; then
        KEY_PATH=~/.ssh/id_httptunnel
        echo "$PRIVATE_KEY_INLINE" > "$KEY_PATH"
        chmod 600 "$KEY_PATH"
    else
        echo "[!] No private key configured. Edit the CONFIG section."
        exit 1
    fi
}

# Parse proxy from environment
parse_proxy() {
    local proxy_var="${HTTPS_PROXY:-$HTTP_PROXY}"
    
    if [[ -n "$proxy_var" ]]; then
        # Format: http://USER:PASS@HOST:PORT or http://HOST:PORT
        if [[ "$proxy_var" =~ @ ]]; then
            PROXY_AUTH=$(echo "$proxy_var" | sed -E 's|https?://([^@]+)@.*|\1|')
            PROXY_HOST=$(echo "$proxy_var" | sed -E 's|https?://[^@]+@([^:]+):([0-9]+).*|\1|')
            PROXY_PORT=$(echo "$proxy_var" | sed -E 's|https?://[^@]+@([^:]+):([0-9]+).*|\2|')
        else
            PROXY_AUTH=""
            PROXY_HOST=$(echo "$proxy_var" | sed -E 's|https?://([^:]+):([0-9]+).*|\1|')
            PROXY_PORT=$(echo "$proxy_var" | sed -E 's|https?://([^:]+):([0-9]+).*|\2|')
        fi
        echo "[*] Using proxy: ${PROXY_HOST}:${PROXY_PORT}"
    else
        PROXY_AUTH=""
        PROXY_HOST=""
        PROXY_PORT=""
        echo "[*] No proxy detected, attempting direct connection"
    fi
}

# Kill any existing tunnel on our port
cleanup() {
    pkill -f "htc -F $LOCAL_PORT" 2>/dev/null || true
    sleep 1
}

# Start the tunnel
start_tunnel() {
    echo "[*] Starting HTTP tunnel..."
    
    local htc_cmd="htc -F $LOCAL_PORT -R $SECRET_PATH ${SERVER_IP}:443"
    
    if [[ -n "$PROXY_HOST" ]]; then
        htc_cmd="htc -F $LOCAL_PORT -P ${PROXY_HOST}:${PROXY_PORT}"
        [[ -n "$PROXY_AUTH" ]] && htc_cmd="$htc_cmd -A $PROXY_AUTH"
        htc_cmd="$htc_cmd -R $SECRET_PATH ${SERVER_IP}:443"
    fi
    
    nohup $htc_cmd >/dev/null 2>&1 &
    sleep 2
    
    if ! pgrep -f "htc -F $LOCAL_PORT" >/dev/null; then
        echo "[!] Tunnel failed to start"
        exit 1
    fi
    
    echo "[*] Tunnel running on localhost:$LOCAL_PORT"
}

# Connect via SSH
connect() {
    echo "[*] Connecting..."
    ssh -p "$LOCAL_PORT" -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "${SSH_USER}@127.0.0.1"
}

# Main
main() {
    install_deps
    setup_key
    parse_proxy
    cleanup
    start_tunnel
    connect
}

main "$@"
