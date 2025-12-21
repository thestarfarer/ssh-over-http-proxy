# SSH Through HTTP Proxy via httptunnel

Persistent SSH access from sandboxed/ephemeral environments that only allow HTTP(S) egress through a corporate proxy.

## The Problem

You're in a container, VM, or corporate environment where:
- Outbound connections are restricted to HTTP/HTTPS through a proxy
- Direct SSH is blocked
- You need shell access to your own infrastructure

## Architecture

```
┌─────────────────┐     HTTPS proxy      ┌──────────────────┐     localhost     ┌─────────────┐
│  Client (htc)   │ ──────────────────►  │  nginx (:443)    │ ───────────────►  │ hts (:8888) │
│  localhost:2222 │      HTTP tunnel     │  HTTP on 443*    │     proxy_pass    │  → sshd:22  │
└─────────────────┘                      └──────────────────┘                   └─────────────┘
         │
         ▼
    ssh -p 2222 root@127.0.0.1
```

*nginx serves **plain HTTP** on port 443. Most corporate proxies assume 443 = HTTPS and pass it through without deep inspection. The tunnel payload looks like HTTP traffic because it *is* HTTP traffic.

## Server Setup

### 1. Install dependencies

```bash
apt-get update && apt-get install -y httptunnel nginx openssh-server
```

### 2. Configure nginx

`/etc/nginx/sites-available/tunnel`:

```nginx
server {
    listen 443;
    server_name _;

    # Secret path prevents discovery
    location /YOUR_SECRET_PATH/ {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Everything else returns nothing useful
    location / {
        return 444;
    }
}
```

```bash
ln -sf /etc/nginx/sites-available/tunnel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
```

### 3. Run httptunnel server

```bash
# As a service or in tmux/screen
hts -F 127.0.0.1:22 8888
```

For persistence, create `/etc/systemd/system/httptunnel.service`:

```ini
[Unit]
Description=HTTP Tunnel Server
After=network.target

[Service]
ExecStart=/usr/bin/hts -F 127.0.0.1:22 8888
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now httptunnel
```

### 4. SSH key-only auth

```bash
# Disable password auth
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# Add your public key
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA... user@client" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

## Client Usage

From the restricted environment:

```bash
#!/bin/bash
set -e

# 1. Install httptunnel client
apt-get install -y httptunnel openssh-client 2>/dev/null || \
  yum install -y httptunnel openssh-clients 2>/dev/null || \
  apk add --no-cache httptunnel openssh-client

# 2. Write your private key
mkdir -p ~/.ssh
cat > ~/.ssh/id_tunnel << 'EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
YOUR_PRIVATE_KEY_HERE
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 600 ~/.ssh/id_tunnel

# 3. Parse proxy from environment
# Expected format: http://USER:PASS@HOST:PORT
if [[ -n "$HTTPS_PROXY" ]]; then
    PROXY_AUTH=$(echo "$HTTPS_PROXY" | sed -E 's|https?://([^@]+)@.*|\1|')
    PROXY_HOST=$(echo "$HTTPS_PROXY" | sed -E 's|https?://([^@]+@)?([^:]+):([0-9]+).*|\2|')
    PROXY_PORT=$(echo "$HTTPS_PROXY" | sed -E 's|https?://([^@]+@)?([^:]+):([0-9]+).*|\3|')
elif [[ -n "$HTTP_PROXY" ]]; then
    PROXY_AUTH=$(echo "$HTTP_PROXY" | sed -E 's|https?://([^@]+)@.*|\1|')
    PROXY_HOST=$(echo "$HTTP_PROXY" | sed -E 's|https?://([^@]+@)?([^:]+):([0-9]+).*|\2|')
    PROXY_PORT=$(echo "$HTTP_PROXY" | sed -E 's|https?://([^@]+@)?([^:]+):([0-9]+).*|\3|')
else
    echo "No proxy configured, attempting direct connection..."
    PROXY_AUTH=""
    PROXY_HOST=""
    PROXY_PORT=""
fi

# 4. Configuration - EDIT THESE
SERVER_IP="YOUR_SERVER_IP"
SECRET_PATH="/YOUR_SECRET_PATH/"
LOCAL_PORT=2222

# 5. Start httptunnel client
if [[ -n "$PROXY_HOST" ]]; then
    nohup htc -F "$LOCAL_PORT" \
        -P "${PROXY_HOST}:${PROXY_PORT}" \
        -A "$PROXY_AUTH" \
        -R "$SECRET_PATH" \
        "${SERVER_IP}:443" >/dev/null 2>&1 &
else
    nohup htc -F "$LOCAL_PORT" \
        -R "$SECRET_PATH" \
        "${SERVER_IP}:443" >/dev/null 2>&1 &
fi

sleep 2

# 6. Connect
ssh -p "$LOCAL_PORT" -i ~/.ssh/id_tunnel \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1
```

## Security Notes

- The secret path is your only access control at the nginx layer. Make it long and random.
- SSH key auth handles actual authentication.
- nginx on 443 with plain HTTP is intentional—looks like HTTPS to the proxy, works like HTTP for the tunnel.
- Consider fail2ban on the SSH side.
- The `-U` flag in htc sets User-Agent if your proxy logs/inspects that.

## Troubleshooting

**htc exits immediately**: Check if the proxy requires authentication. The `-A user:pass` flag is required for authenticated proxies.

**Connection hangs**: The proxy might be doing deep packet inspection. Try a different egress path or accept that this environment is too locked down.

**"Connection refused" on localhost:2222**: htc isn't running or died. Check with `ps aux | grep htc`. Make sure you're backgrounding properly with `nohup ... &`.

**SSH host key warnings**: Normal for first connection. The `-o StrictHostKeyChecking=no` flag handles this, but remove it in production if you want to verify the host key.

## Why This Works

Most corporate proxies:
1. Allow CONNECT to port 443 (assumed HTTPS)
2. Don't deeply inspect traffic on 443
3. Pass through anything that looks vaguely HTTP-shaped

httptunnel wraps arbitrary TCP (in this case SSH) in HTTP requests. nginx provides the endpoint. The proxy thinks it's web traffic. Everyone's happy.

## License

Do whatever you want with this. It's plumbing.
