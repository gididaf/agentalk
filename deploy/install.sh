#!/bin/bash
# Provision a fresh Ubuntu host for the agentalk bridge.
# Usage: run as root on a clean Ubuntu 22.04+ machine.
set -euo pipefail

echo "=== apt update + prereqs ==="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates gnupg lsb-release \
    debian-keyring debian-archive-keyring apt-transport-https \
    jq ufw git

echo "=== install Node 22 (NodeSource) ==="
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
fi
node --version

echo "=== install Caddy ==="
if ! command -v caddy >/dev/null 2>&1; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy
fi
caddy version

echo "=== create agentalk system user ==="
id agentalk >/dev/null 2>&1 || \
    useradd --system --home /opt/agentalk --shell /usr/sbin/nologin agentalk
mkdir -p /opt/agentalk /etc/agentalk
chown agentalk:agentalk /opt/agentalk

echo "=== done — next steps ==="
echo "1. rsync source into /opt/agentalk (excluding node_modules, dist, .git)"
echo "2. cd /opt/agentalk && sudo -u agentalk npm ci && sudo -u agentalk npm run build"
echo "3. cp deploy/env.example /etc/agentalk/env  (and edit as needed)"
echo "4. cp deploy/agentalk.service /etc/systemd/system/"
echo "5. cp deploy/Caddyfile /etc/caddy/Caddyfile  (edit the email + hostname)"
echo "6. systemctl daemon-reload && systemctl enable --now agentalk && systemctl reload caddy"
echo "7. ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw enable"
