#!/usr/bin/env bash

# Masjid Center - Multi-OS Deployment Script
# Automatically detects OS and configures network mode and host information

set -e

echo "🕌 Masjid Center - Starting deployment..."
echo ""

# Detect OS
OS=$(uname -s)
echo "🔍 Detected OS: $OS"

# Bridge on every OS — the iOS app locates the server by scanning the subnet
# on :7777, so host networking is not required. On Linux, run
# `NETWORK_MODE=host ./start.sh` to opt back into host networking.
export NETWORK_MODE=${NETWORK_MODE:-bridge}
echo "✅ Network mode: $NETWORK_MODE"
echo ""

# Detect hostname
if [ "$OS" = "Darwin" ]; then
    HOST_HOSTNAME=$(scutil --get ComputerName 2>/dev/null || hostname)
else
    HOST_HOSTNAME=$(hostname)
fi

# Detect the LAN IP so the container can display the right server address.
if [ "$OS" = "Darwin" ]; then
    # macOS - get first non-loopback IPv4
    HOST_IP=$(ifconfig | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | head -1)
else
    # Linux / Windows (Git Bash, WSL)
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(ip addr show | grep "inet " | grep -v "127.0.0.1" | awk '{print $2}' | cut -d'/' -f1 | head -1)
    fi
fi

# Fallback if detection failed
if [ -z "$HOST_IP" ]; then
    HOST_IP="host.docker.internal"
    echo "⚠️  Could not detect IP, using fallback: $HOST_IP"
fi

export HOST_HOSTNAME
export HOST_IP

echo "📋 Configuration:"
echo "   Hostname: $HOST_HOSTNAME"
echo "   IP Address: $HOST_IP"
echo ""

# Start Docker Compose
echo "🚀 Starting Docker container..."
docker-compose up -d

echo ""
echo "✅ Masjid Center started successfully!"
echo ""

echo "📱 Access the web interface:"
echo "   Local:  http://localhost:7777"
echo "   Network: http://$HOST_IP:7777"

echo ""
echo "📊 View logs: docker-compose logs -f"
echo "🛑 Stop: docker-compose down"
echo ""
