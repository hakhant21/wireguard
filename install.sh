#!/bin/bash

set -e

echo "=== Wireguard + Xray Server Installer (LXC Compatible) ==="

# Configuration variables
WG_PORT=21821
XRAY_PORT=10000
WG_SUBNET="120.76.0.0/24"
WG_NETWORK="120.76.0"
DB_DIR="/etc/wg-xray"
BACKUP_DIR="/root/wireguard/wg-xray-backups"
UNINSTALL_SCRIPT="/usr/local/bin/wgx-uninstall"
WGX_OWNER="${SUDO_USER:-root}"
if ! id "$WGX_OWNER" >/dev/null 2>&1; then
    WGX_OWNER="root"
fi

append_if_missing() {
    local line=$1
    local file=$2

    if ! grep -qxF "$line" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
    fi
}

normalize_users_db() {
    local db_file=$1
    local tmp_file

    [ -f "$db_file" ] || return 0

    tmp_file=$(mktemp)
    awk -F',' 'BEGIN {OFS=","} NF >= 5 {print $1, $2, $3, $5; next} {print}' "$db_file" > "$tmp_file"
    cat "$tmp_file" > "$db_file"
    rm -f "$tmp_file"
}

# ========================
# DETECT LXC ENVIRONMENT
# ========================
IS_LXC=false
if [ -f /proc/1/environ ] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    IS_LXC=true
    echo "✓ LXC container detected"
fi

# ========================
# Get the ACTUAL outbound interface that reaches internet
# ========================
IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
if [ -z "$IFACE" ]; then
    IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
fi
echo "Detected outbound interface: $IFACE"

# ========================
# Disable rp_filter for WireGuard in LXC
# ========================
if [ "$IS_LXC" = true ]; then
    echo "=== Applying LXC-specific fixes ==="
    
    sysctl -w net.ipv4.conf.all.rp_filter=2
    sysctl -w net.ipv4.conf.default.rp_filter=2
    sysctl -w net.ipv4.conf.$IFACE.rp_filter=2
    
    append_if_missing "# WireGuard LXC fixes" /etc/sysctl.conf
    append_if_missing "net.ipv4.conf.all.rp_filter=2" /etc/sysctl.conf
    append_if_missing "net.ipv4.conf.default.rp_filter=2" /etc/sysctl.conf
    append_if_missing "net.ipv4.conf.$IFACE.rp_filter=2" /etc/sysctl.conf
    
    echo "✓ rp_filter set to loose mode"
fi

# ========================
# DETECT NETBIRD IN DOCKER
# ========================
NETBIRD_ACTIVE=false
NETBIRD_INTERFACE=""

if command -v docker &>/dev/null && docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "netbird"; then
    echo "✓ Netbird Docker container detected"
    NETBIRD_ACTIVE=true
    
    if ip link show | grep -q "netbird"; then
        NETBIRD_INTERFACE="netbird"
    elif ip link show | grep -q "wt0"; then
        NETBIRD_INTERFACE="wt0"
    fi
    
    if [ -n "$NETBIRD_INTERFACE" ]; then
        echo "✓ Netbird interface: $NETBIRD_INTERFACE"
    fi
fi

# ========================
# INSTALL DEPENDENCIES
# ========================
echo "=== Installing Dependencies ==="
apt update -y
apt install -y wireguard curl iptables jq qrencode ufw fail2ban unzip wget

# Create directories
mkdir -p "$DB_DIR" "$BACKUP_DIR"
chmod 750 "$DB_DIR"
chmod 755 "$BACKUP_DIR"

# ========================
# FIREWALL SETUP
# ========================
echo "=== Configuring Firewall ==="
if ! ufw status | grep -q "Status: active"; then
    ufw --force enable
fi

ufw default deny incoming
ufw default allow outgoing

ufw allow ssh
ufw allow "$WG_PORT"/udp
ufw allow "$XRAY_PORT"/tcp

sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw 2>/dev/null || true
ufw --force reload

# ========================
# IP FORWARDING
# ========================
echo "=== Enabling IP Forwarding ==="
sysctl -w net.ipv4.ip_forward=1
append_if_missing "net.ipv4.ip_forward=1" /etc/sysctl.conf

# ========================
# WIREGUARD SETUP
# ========================
echo "=== Setting up WireGuard ==="

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
rm -f /etc/wireguard/wg0.conf 2>/dev/null

wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)
SERVER_PUB=$(cat /etc/wireguard/server_public.key)

# Create WireGuard config
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = ${WG_NETWORK}.1/24
ListenPort = $WG_PORT
MTU = 1420

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = sysctl -w net.ipv4.conf.all.rp_filter=2
PostUp = sysctl -w net.ipv4.conf.$IFACE.rp_filter=2
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o $IFACE -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o $IFACE -j MASQUERADE
EOF

# Add Netbird routing if detected
if [ "$NETBIRD_ACTIVE" = true ] && [ -n "$NETBIRD_INTERFACE" ]; then
    cat >> /etc/wireguard/wg0.conf <<EOF

# Netbird integration
PostUp = iptables -A FORWARD -i wg0 -o $NETBIRD_INTERFACE -j ACCEPT
PostUp = iptables -A FORWARD -i $NETBIRD_INTERFACE -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o $NETBIRD_INTERFACE -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -o $NETBIRD_INTERFACE -j ACCEPT
PostDown = iptables -D FORWARD -i $NETBIRD_INTERFACE -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o $NETBIRD_INTERFACE -j MASQUERADE
EOF
fi

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl stop wg-quick@wg0 2>/dev/null || true

echo "Starting WireGuard..."
systemctl start wg-quick@wg0

sleep 3

# Verify WireGuard
if systemctl is-active --quiet wg-quick@wg0; then
    echo "✓ WireGuard running"
else
    echo "⚠️ WireGuard failed to start. Checking logs..."
    journalctl -u wg-quick@wg0 -n 20 --no-pager
    
    echo ""
    echo "Attempting to fix common issues..."

    echo "Retrying with existing IPv4 configuration..."
    systemctl restart wg-quick@wg0
    sleep 2
    
    if systemctl is-active --quiet wg-quick@wg0; then
        echo "✓ WireGuard running after retry"
    else
        echo "✗ WireGuard still failing. Manual intervention required."
        echo "Config file: /etc/wireguard/wg0.conf"
        journalctl -u wg-quick@wg0 -n 10 --no-pager
        exit 1
    fi
fi

# Show WireGuard status
echo ""
echo "WireGuard interface status:"
wg show

# ========================
# XRAY INSTALL - FIXED WITH FALLBACK
# ========================
echo "=== Installing Xray ==="

XRAY_INSTALL_SUCCESS=false

# Method 1: Try official install script with error handling
echo "Attempting official Xray installation..."
if curl -sL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh -o /tmp/xray-install.sh; then
    chmod +x /tmp/xray-install.sh
    if bash /tmp/xray-install.sh install 2>&1 | tee /tmp/xray-install.log; then
        XRAY_INSTALL_SUCCESS=true
        echo "✓ Xray installed via official script"
    else
        echo "⚠️ Official install script failed, checking log..."
        cat /tmp/xray-install.log
    fi
else
    echo "⚠️ Could not download official install script"
fi

# Method 2: Manual installation if official script fails
if [ "$XRAY_INSTALL_SUCCESS" = false ]; then
    echo "=== Performing manual Xray installation ==="
    
    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  XRAY_ARCH="linux-64" ;;
        aarch64) XRAY_ARCH="linux-arm64-v8a" ;;
        armv7l)  XRAY_ARCH="linux-arm32-v7a" ;;
        *)       
            echo "Unsupported architecture: $ARCH"
            echo "Attempting linux-64 as fallback..."
            XRAY_ARCH="linux-64"
            ;;
    esac
    
    # Download Xray
    XRAY_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -o '"tag_name": "[^"]*' | grep -o '[^"]*$')
    if [ -z "$XRAY_VERSION" ]; then
        XRAY_VERSION="v1.8.21"
        echo "Using default version: $XRAY_VERSION"
    fi
    
    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-${XRAY_ARCH}.zip"
    echo "Downloading Xray from: $DOWNLOAD_URL"
    
    cd /tmp
    if wget -O xray.zip "$DOWNLOAD_URL"; then
        unzip -o xray.zip
        
        mkdir -p /usr/local/bin
        cp xray /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
        
        mkdir -p /usr/local/etc/xray
        mkdir -p /usr/local/share/xray
        cp geoip.dat geosite.dat /usr/local/share/xray/ 2>/dev/null || true
        
        # Create systemd service
        cat > /etc/systemd/system/xray.service <<'SERVICEEOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICEEOF
        
        systemctl daemon-reload
        echo "✓ Xray installed manually"
    else
        echo "✗ Failed to download Xray"
        exit 1
    fi
    
    cd - > /dev/null
fi

# Verify Xray installation
if ! command -v xray &>/dev/null; then
    if [ -f /usr/local/bin/xray ]; then
        export PATH="/usr/local/bin:$PATH"
    else
        XRAY_BIN=$(find / -name xray -type f -executable 2>/dev/null | head -1)
        if [ -n "$XRAY_BIN" ]; then
            echo "Found Xray at: $XRAY_BIN"
            ln -sf "$XRAY_BIN" /usr/local/bin/xray 2>/dev/null || true
        else
            echo "✗ Xray installation failed completely"
            exit 1
        fi
    fi
fi

# Test Xray
if /usr/local/bin/xray version &>/dev/null; then
    echo "✓ Xray binary working"
else
    echo "✗ Xray binary not working"
    exit 1
fi

# Generate Xray keys
echo "Generating Xray Reality keys..."
KEYS=$(/usr/local/bin/xray x25519 2>&1) || {
    echo "✗ Failed to generate x25519 keys"
    exit 1
}

XRAY_PRIV=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
XRAY_PUB=$(echo "$KEYS" | grep -i "public" | awk '{print $NF}')

if [ -z "$XRAY_PRIV" ] || [ -z "$XRAY_PUB" ]; then
    echo "✗ Failed to parse Xray keys"
    exit 1
fi

echo "✓ Xray keys generated"

# Save keys
echo "$XRAY_PUB" > "$DB_DIR/xray_public.key"
echo "$XRAY_PRIV" > "$DB_DIR/xray_private.key"
chmod 600 "$DB_DIR/xray_private.key"
chmod 644 "$DB_DIR/xray_public.key"

# Create Xray config
mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "realitySettings": {
          "dest": "www.google.com:443",
          "serverNames": [
            "www.google.com",
            "fonts.gstatic.com"
          ],
          "privateKey": "$XRAY_PRIV",
          "shortIds": ["6ba85179e30d4fc2"]
        },
        "grpcSettings": {
          "serviceName": "grpc"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

# Setup log directory and permissions
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log

# Detect Xray service user
XRAY_SERVICE_USER=""
XRAY_SERVICE_GROUP=""

if [ -f /etc/systemd/system/xray.service ]; then
    XRAY_SERVICE_USER=$(grep "^User=" /etc/systemd/system/xray.service | cut -d'=' -f2)
    XRAY_SERVICE_GROUP=$(grep "^Group=" /etc/systemd/system/xray.service | cut -d'=' -f2 2>/dev/null || echo "")
elif [ -f /usr/lib/systemd/system/xray.service ]; then
    XRAY_SERVICE_USER=$(grep "^User=" /usr/lib/systemd/system/xray.service | cut -d'=' -f2)
    XRAY_SERVICE_GROUP=$(grep "^Group=" /usr/lib/systemd/system/xray.service | cut -d'=' -f2 2>/dev/null || echo "")
fi

if [ -z "$XRAY_SERVICE_USER" ]; then
    XRAY_SERVICE_USER="nobody"
fi
if [ -z "$XRAY_SERVICE_GROUP" ]; then
    XRAY_SERVICE_GROUP=$(id -gn "$XRAY_SERVICE_USER" 2>/dev/null || echo "nogroup")
fi

echo "Xray will run as: $XRAY_SERVICE_USER:$XRAY_SERVICE_GROUP"

# Create user if needed
if ! id "$XRAY_SERVICE_USER" >/dev/null 2>&1 && [ "$XRAY_SERVICE_USER" != "root" ]; then
    useradd -r -s /bin/false "$XRAY_SERVICE_USER" 2>/dev/null || true
fi

# Set permissions
chown -R "$XRAY_SERVICE_USER:$XRAY_SERVICE_GROUP" /var/log/xray 2>/dev/null || true
chmod 750 /var/log/xray
chmod 640 /var/log/xray/access.log /var/log/xray/error.log

# Test Xray config
echo "Testing Xray configuration..."
if /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1; then
    echo "✓ Xray configuration valid"
else
    echo "⚠️ Xray configuration test failed, but continuing..."
fi

# Enable and start Xray
systemctl enable xray 2>/dev/null || true
systemctl restart xray || {
    echo "⚠️ Failed to restart Xray service. Checking status:"
    systemctl status xray --no-pager -l || true
}

sleep 2

# Verify Xray is running
if systemctl is-active --quiet xray 2>/dev/null; then
    echo "✓ Xray service running"
elif pgrep -x xray > /dev/null; then
    echo "⚠️ Xray running but not via systemd"
else
    echo "✗ Xray failed to start"
fi

# ========================
# USER DATABASE & CLI TOOL
# ========================
echo "=== Setting up CLI tools ==="
touch "$DB_DIR/users.db"
normalize_users_db "$DB_DIR/users.db"
chmod 644 "$DB_DIR/users.db"

echo "$(date)" > "$DB_DIR/.installed"

# ========================
# CLI TOOL
# ========================
cat > /usr/local/bin/wgx <<'CLIEOF'
#!/bin/bash

DB="/etc/wg-xray/users.db"
WG_CONF="/etc/wireguard/wg0.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
BACKUP_DIR="/root/wireguard/wg-xray-backups"
WG_PORT="21821"
XRAY_PORT="10000"
WG_BASE="120.76.0"
WG_DNS="1.1.1.1, 8.8.8.8"

USE_SUDO=""
if [ "$EUID" -ne 0 ]; then
    USE_SUDO="sudo"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

normalize_db() {
    local tmp

    [ -f "$DB" ] || return 0

    tmp=$(mktemp)
    awk -F',' 'BEGIN {OFS=","} NF >= 5 {print $1, $2, $3, $5; next} {print}' "$DB" > "$tmp"
    $USE_SUDO mv "$tmp" "$DB"
    $USE_SUDO chmod 644 "$DB"
}

normalize_db

get_next_ip() {
    if [ ! -f "$DB" ]; then
        echo "$WG_BASE.2"
        return
    fi
    LAST=$(awk -F',' '{print $3}' "$DB" 2>/dev/null | awk -F'.' '{print $4}' | sort -n | tail -1)
    if [ -z "$LAST" ] || [ "$LAST" -lt 2 ]; then
        echo "$WG_BASE.2"
    else
        echo "$WG_BASE.$((LAST+1))"
    fi
}

backup_configs() {
    NAME=$1
    [ -z "$NAME" ] && NAME="manual"
    FILE="$BACKUP_DIR/backup_${NAME}.tar.gz"
    $USE_SUDO mkdir -p "$BACKUP_DIR"
    $USE_SUDO tar -czf "$FILE" "$WG_CONF" "$XRAY_CONF" "$DB" 2>/dev/null || true
    log "Backup: $FILE"
}

sync_xray() {
    if [ ! -f "$DB" ]; then
        $USE_SUDO touch "$DB"
        $USE_SUDO chmod 644 "$DB"
    fi
    
    CLIENTS=$(awk -F',' '{printf "{\"id\":\"%s\"},",$2}' "$DB" 2>/dev/null | sed 's/,$//')
    
    if [ -z "$CLIENTS" ]; then
        CLIENTS=""
    fi
    
    $USE_SUDO jq ".inbounds[0].settings.clients = [ $CLIENTS ]" "$XRAY_CONF" > /tmp/xray.json
    $USE_SUDO mv /tmp/xray.json "$XRAY_CONF"
    
    if systemctl is-active --quiet xray 2>/dev/null; then
        $USE_SUDO systemctl restart xray
    fi
    log "XRAY configuration synced"
}

generate_qr() {
    USER=$1
    UUID=$2
    
    SERVER_IP=$(curl -s ifconfig.me)
    if [ -f "/etc/wg-xray/xray_public.key" ]; then
        PUB_KEY=$(cat /etc/wg-xray/xray_public.key)
    else
        PUB_KEY=""
    fi
    
    XRAY_LINK="vless://$UUID@$SERVER_IP:$XRAY_PORT?type=grpc&security=reality&serviceName=grpc&pbk=$PUB_KEY&sni=www.google.com#$USER"
    
    echo ""
    echo -e "${GREEN}===== XRAY LINK =====${NC}"
    echo "$XRAY_LINK"
    qrencode -t ansiutf8 "$XRAY_LINK" 2>/dev/null || echo "QR code generation failed"
    
    echo ""
    echo -e "${GREEN}===== WG QR =====${NC}"
    if [ -f "$BACKUP_DIR/wg-$USER.conf" ]; then
        qrencode -t ansiutf8 < "$BACKUP_DIR/wg-$USER.conf" 2>/dev/null || echo "QR code generation failed"
    fi
}

add_user() {
    USER=$1
    
    if [ -z "$USER" ]; then
        error "Username required"
        echo "Usage: wgx add USERNAME"
        return 1
    fi
    
    if [ -f "$DB" ] && grep -q "^$USER," "$DB"; then
        error "User $USER already exists"
        return 1
    fi
    
    IP=$(get_next_ip)
    WG_KEY=$($USE_SUDO wg genkey)
    PRIV="$WG_KEY"
    PUB=$(echo "$WG_KEY" | $USE_SUDO wg pubkey)
    UUID=$(cat /proc/sys/kernel/random/uuid)
    
    $USE_SUDO bash -c "echo \"$USER,$UUID,$IP,$PUB\" >> \"$DB\""
    
    $USE_SUDO bash -c "cat >> \"$WG_CONF\" <<EOC

[Peer]
PublicKey = $PUB
AllowedIPs = $IP/32
EOC"
    
    $USE_SUDO systemctl restart wg-quick@wg0
    
    SERVER_IP=$(curl -s ifconfig.me)
    SERVER_PUB=$($USE_SUDO cat /etc/wireguard/server_public.key)
    
    $USE_SUDO mkdir -p "$BACKUP_DIR"

    $USE_SUDO tee "$BACKUP_DIR/wg-$USER.conf" > /dev/null <<EOC
[Interface]
PrivateKey = $PRIV
Address = $IP/24
DNS = $WG_DNS
MTU = 1420

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOC
    
    sync_xray
    backup_configs "$USER"
    
    echo ""
    echo -e "${GREEN}=== USER CREATED ===${NC}"
    echo "Username: $USER"
    echo "IPv4: $IP"
    echo "UUID: $UUID"
    echo "WG Config: $BACKUP_DIR/wg-$USER.conf"
    
    generate_qr "$USER" "$UUID"
}

remove_user() {
    USER=$1
    
    if [ -z "$USER" ]; then
        error "Username required"
        echo "Usage: wgx remove USERNAME"
        return 1
    fi
    
    if [ ! -f "$DB" ]; then
        error "No users found"
        return 1
    fi
    
    line=$(grep "^$USER," "$DB")
    if [ -z "$line" ]; then
        error "User $USER not found"
        return 1
    fi
    
    $USE_SUDO sed -i "/^$USER,/d" "$DB"
    
    TMP=$(mktemp)
    
    $USE_SUDO awk '
    BEGIN {keep=1}
    /^\[Peer\]/ {keep=0}
    keep {print}
    ' "$WG_CONF" > "$TMP"
    
    while IFS=',' read -r u uuid ip pub rest; do
        [ -z "$u" ] && continue
        echo "" >> "$TMP"
        echo "[Peer]" >> "$TMP"
        echo "PublicKey = $pub" >> "$TMP"
        echo "AllowedIPs = $ip/32" >> "$TMP"
    done < "$DB"
    
    $USE_SUDO mv "$TMP" "$WG_CONF"
    
    $USE_SUDO systemctl restart wg-quick@wg0
    sync_xray
    
    $USE_SUDO rm -f "$BACKUP_DIR/wg-$USER.conf" "$BACKUP_DIR/$USER-xray-link.txt" 2>/dev/null
    
    echo -e "${GREEN}User removed: $USER${NC}"
}

list_users() {
    if [ ! -f "$DB" ] || [ ! -s "$DB" ]; then
        echo "No users found"
        return
    fi
    
    printf "%-15s %-36s %-16s\n" "USERNAME" "UUID" "IPv4"
    echo "--------------------------------------------------------------------------"
    
    while IFS=',' read -r user uuid ip pub rest; do
        printf "%-15s %-36s %-16s\n" "$user" "$uuid" "$ip"
    done < "$DB"
}

show_user() {
    USER=$1
    
    if [ -z "$USER" ]; then
        error "Username required"
        return 1
    fi
    
    if [ ! -f "$DB" ]; then
        error "No users found"
        return 1
    fi
    
    line=$(grep "^$USER," "$DB")
    if [ -z "$line" ]; then
        error "User $USER not found"
        return 1
    fi
    
    IFS=',' read -r user uuid ip pub rest <<< "$line"
    
    echo -e "${GREEN}User Details:${NC}"
    echo "Username: $user"
    echo "UUID: $uuid"
    echo "IPv4: $ip"
    echo "Public Key: $pub"
    
    if [ -f "$BACKUP_DIR/wg-$user.conf" ]; then
        echo ""
        echo "WireGuard Configuration:"
        cat "$BACKUP_DIR/wg-$user.conf"
        generate_qr "$user" "$uuid"
    else
        echo "Configuration files not found"
    fi
}

case "$1" in
    add)
        add_user "$2"
        ;;
    remove)
        remove_user "$2"
        ;;
    list)
        list_users
        ;;
    show)
        show_user "$2"
        ;;
    backup)
        backup_configs "$2"
        echo "Backup created in $BACKUP_DIR"
        ;;
    *)
        echo "Usage: wgx {add|remove|list|show|backup}"
        echo ""
        echo "Commands:"
        echo "  add USERNAME     - Add new user with WireGuard and Xray configs"
        echo "  remove USERNAME  - Remove user and revoke access"
        echo "  list             - List all users"
        echo "  show USERNAME    - Show user details, QR codes, and config"
        echo "  backup           - Create configuration backup"
        ;;
esac
CLIEOF

chmod +x /usr/local/bin/wgx

# Add invoking user to sudoers (when installer was run with sudo)
if [ "$WGX_OWNER" != "root" ]; then
    echo "$WGX_OWNER ALL=(ALL) NOPASSWD: /usr/local/bin/wgx" > /etc/sudoers.d/wgx
    chmod 440 /etc/sudoers.d/wgx
fi

# ========================
# CREATE UNINSTALL SCRIPT
# ========================
cat > "$UNINSTALL_SCRIPT" <<'UNINSTALLEOF'
#!/bin/bash

echo "=== WireGuard + Xray Uninstaller ==="
read -p "Are you sure? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

BACKUP_FILE="/tmp/wg-xray-final-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$BACKUP_FILE" /etc/wireguard /usr/local/etc/xray /etc/wg-xray 2>/dev/null || true
echo "✓ Backup saved to $BACKUP_FILE"

systemctl stop wg-quick@wg0 2>/dev/null
systemctl stop xray 2>/dev/null
systemctl disable wg-quick@wg0 2>/dev/null
systemctl disable xray 2>/dev/null

ip link del wg0 2>/dev/null
rm -rf /etc/wireguard
rm -rf /usr/local/etc/xray
rm -rf /usr/local/share/xray
rm -rf /var/log/xray
rm -rf /etc/wg-xray
rm -rf /root/wireguard/wg-xray-backups
rm -f /usr/local/bin/wgx
rm -f /usr/local/bin/xray
rm -f /etc/sudoers.d/wgx
rm -f /etc/systemd/system/xray.service
systemctl daemon-reload

# Clean iptables (IPv4)
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null

echo "=== Uninstall Complete ==="
UNINSTALLEOF

chmod +x "$UNINSTALL_SCRIPT"

# Save iptables
echo "=== Saving iptables rules ==="
apt install -y iptables-persistent 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

# ========================
# VERIFICATION
# ========================
echo ""
echo "============================================"
echo "           VERIFICATION RESULTS"
echo "============================================"
echo ""

# WireGuard status
echo "WireGuard:"
if systemctl is-active --quiet wg-quick@wg0; then
    echo "  ✓ Service: Running"
    wg show
else
    echo "  ✗ Service: Failed"
fi

# Xray status
echo ""
echo "Xray:"
if systemctl is-active --quiet xray 2>/dev/null; then
    echo "  ✓ Service: Running"
elif pgrep -x xray > /dev/null; then
    echo "  ⚠️  Running but not via systemd"
else
    echo "  ✗ Service: Failed"
fi

# Netbird status
if [ "$NETBIRD_ACTIVE" = true ]; then
    echo ""
    echo "Netbird:"
    docker ps --format "table {{.Names}}" 2>/dev/null | grep -q netbird && echo "  ✓ Running" || echo "  ⚠️  Not detected"
fi

# Get server IPs
SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "============================================"
echo "         INSTALLATION COMPLETE"
echo "============================================"
echo ""
echo "Server Information:"
echo "  IPv4:        $SERVER_IP"
echo "  WG Port:     $WG_PORT/udp"
echo "  Xray Port:   $XRAY_PORT/tcp"
echo ""
echo "Management Commands:"
echo "  wgx add USERNAME    - Add new user"
echo "  wgx list            - List all users"
echo "  wgx show USERNAME   - Show user details & QR codes"
echo "  wgx remove USERNAME - Remove user"
echo "  wgx backup          - Backup configurations"
echo ""
echo "Uninstall:"
echo "  sudo wgx-uninstall"
echo ""
echo "Configuration Files:"
echo "  WireGuard:  /etc/wireguard/wg0.conf"
echo "  Xray:       /usr/local/etc/xray/config.json"
echo "  Users DB:   $DB_DIR/users.db"
echo "  Backups:    $BACKUP_DIR"
echo ""
echo "============================================"
