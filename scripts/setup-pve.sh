#!/usr/bin/env bash
set -Eeuo pipefail

HOST_IP=""
LAN_CIDR=""
WINDOWS_MCP_IP=""
WINDOWS_MCP_PORT=8082
HTTPS_PORT=8081
MCP_API_KEY=""
AUTH_USER=dsh
AUTH_PASSWORD=""

usage() {
  cat <<'EOF'
DSH-LAN PVE setup (experimental / not yet validated)

Required/typical options:
  --host-ip IP
  --lan-cidr CIDR
  --windows-mcp-ip IP
  --windows-mcp-port PORT   (default 8082)
  --mcp-api-key KEY
  --https-port PORT         (default 8081)
  --auth-user USER          (default dsh)
  --auth-password PASS      (generated if omitted)
EOF
}

while (($#)); do
  case "$1" in
    --host-ip) HOST_IP="$2"; shift 2;;
    --lan-cidr) LAN_CIDR="$2"; shift 2;;
    --windows-mcp-ip) WINDOWS_MCP_IP="$2"; shift 2;;
    --windows-mcp-port) WINDOWS_MCP_PORT="$2"; shift 2;;
    --mcp-api-key) MCP_API_KEY="$2"; shift 2;;
    --https-port) HTTPS_PORT="$2"; shift 2;;
    --auth-user) AUTH_USER="$2"; shift 2;;
    --auth-password) AUTH_PASSWORD="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root/sudo.' >&2; exit 1; }

if [[ -z "$HOST_IP" ]]; then
  HOST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
fi
[[ -n "$HOST_IP" ]] || read -r -p 'PVE LAN IPv4: ' HOST_IP

if [[ -z "$LAN_CIDR" ]]; then
  IFS=. read -r a b c _ <<<"$HOST_IP"
  LAN_CIDR="$a.$b.$c.0/24"
fi

[[ -n "$WINDOWS_MCP_IP" ]] || read -r -p 'Windows Filesystem MCP IPv4: ' WINDOWS_MCP_IP

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx apache2-utils openssl ca-certificates

command -v node >/dev/null || { echo 'Node.js is required.' >&2; exit 1; }
command -v npx >/dev/null || { echo 'npx is required.' >&2; exit 1; }

if ! node -e 'const [M,m]=process.versions.node.split(".").map(Number);process.exit((M===22&&m>=19)||M>=24?0:1)'; then
  echo "Node $(node -v) is too old for the tested DSH tree; use Node 22.19+ or 24+." >&2
  exit 1
fi

[[ -n "$MCP_API_KEY" ]] || MCP_API_KEY="$(openssl rand -hex 32)"
[[ "$MCP_API_KEY" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || { echo 'Invalid MCP API key format.' >&2; exit 1; }
[[ -n "$AUTH_PASSWORD" ]] || AUTH_PASSWORD="$(openssl rand -hex 12)"

BASE=/etc/dsh-lan
TLS="$BASE/tls"
PATCH="$BASE/windows-files.cordis.yml"
mkdir -p "$TLS"
chmod 700 "$BASE" "$TLS"

if [[ ! -f "$TLS/dsh-lan-ca.key" ]]; then
  openssl genrsa -out "$TLS/dsh-lan-ca.key" 4096
  openssl req -x509 -new -nodes -key "$TLS/dsh-lan-ca.key" -sha256 -days 3650 \
    -out "$TLS/dsh-lan-ca.crt" -subj '/CN=DSH LAN Local CA'
fi

openssl genrsa -out "$TLS/dsh-lan.key" 2048
openssl req -new -key "$TLS/dsh-lan.key" -out "$TLS/dsh-lan.csr" -subj "/CN=$HOST_IP"
cat > "$TLS/dsh-lan.ext" <<EOF
subjectAltName = IP:$HOST_IP
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in "$TLS/dsh-lan.csr" -CA "$TLS/dsh-lan-ca.crt" -CAkey "$TLS/dsh-lan-ca.key" \
  -CAcreateserial -out "$TLS/dsh-lan.crt" -days 825 -sha256 -extfile "$TLS/dsh-lan.ext"
chmod 600 "$TLS"/*.key

htpasswd -bcB "$BASE/htpasswd" "$AUTH_USER" "$AUTH_PASSWORD" >/dev/null
chmod 600 "$BASE/htpasswd"

cat > "$PATCH" <<EOF
- insert:
    - id: mcp-windows-files
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: windows-files
        transport: streamable-http
        url: http://$WINDOWS_MCP_IP:$WINDOWS_MCP_PORT/mcp
        headers:
          X-API-Key: '$MCP_API_KEY'
        toolCallTimeoutMs: 60000
        failOnStartupError: false
        reconnect:
          enabled: true
          initialDelayMs: 500
          maxDelayMs: 30000
          maxAttempts: 10
EOF
chmod 600 "$PATCH"

cat > /etc/nginx/sites-available/dsh-lan <<EOF
server {
    listen $HTTPS_PORT ssl;
    server_name $HOST_IP;

    ssl_certificate     $TLS/dsh-lan.crt;
    ssl_certificate_key $TLS/dsh-lan.key;

    allow $LAN_CIDR;
    deny all;

    auth_basic "DeepSeek Harness";
    auth_basic_user_file $BASE/htpasswd;

    location / {
        proxy_pass http://127.0.0.1:3080;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1:3080;
        proxy_set_header Origin "";
        proxy_set_header Authorization "";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

ln -sfn /etc/nginx/sites-available/dsh-lan /etc/nginx/sites-enabled/dsh-lan
nginx -t
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx

cat > /usr/local/sbin/dsh-lan-run <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$(dirname "$(command -v node)"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
exec "$(command -v npx)" -y @deepseek-ai/dsh web --patch "$PATCH"
EOF
chmod 755 /usr/local/sbin/dsh-lan-run

cat > /etc/systemd/system/dsh-lan.service <<'EOF'
[Unit]
Description=DeepSeek Harness LAN
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/dsh-lan-run
Restart=on-failure
RestartSec=3
WorkingDirectory=/root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dsh-lan.service

cat <<EOF

DSH-LAN setup complete (DRAFT / NOT YET VALIDATED)

Web URL:        https://$HOST_IP:$HTTPS_PORT
Basic user:     $AUTH_USER
Basic password: $AUTH_PASSWORD
MCP endpoint:   http://$WINDOWS_MCP_IP:$WINDOWS_MCP_PORT/mcp
MCP X-API-Key:  $MCP_API_KEY
Cordis patch:   $PATCH
Browser CA:     $TLS/dsh-lan-ca.crt

Windows browser trust step:
  scp root@$HOST_IP:$TLS/dsh-lan-ca.crt .
  certutil -addstore -f ROOT .\\dsh-lan-ca.crt

Security: keep the Web UI and MCP endpoint on a trusted LAN/VPN. Do not expose them to the public Internet.
EOF
