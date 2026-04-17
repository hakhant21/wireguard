#!/bin/bash

set -e

echo "=== Wireguard + Xray Server Installer (Netbird Docker Compatible) ==="

# Configuration variables
WG_PORT=21821  # Different from Netbird's default 51820
XRAY_PORT=10000
WG_SUBNET="120.76.0.0/24"
WG_NETWORK="120.76.0"
DB_DIR="/etc/wg-xray"
BACKUP_DIR="/home/pos/wireguard/wg-xray-backups"

# ========================
# DETECT NETBIRD IN DOCKER
# ========================
NETBIRD_ACTIVE=false
NETBIRD_INTERFACE=""
NETBIRD_NETWORK=""

# Check for Netbird Docker container
if docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "netbird"; then
    echo "✓ Netbird Docker container detected"
    NETBIRD_ACTIVE=true
    
    # Get Netbird interface name
    if ip link show | grep -q "netbird"; then
        NETBIRD_INTERFACE="netbird"
    elif ip link show | grep -q "wt0"; then
        NETBIRD_INTERFACE="wt0"
    fi
    
    # Get Netbird network IP range
    if [ -n "$NETBIRD_INTERFACE" ]; then
        NETBIRD_NETWORK=$(ip addr show $NETBIRD_INTERFACE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
        echo "✓ Netbird interface: $NETBIRD_INTERFACE"
        echo "✓ Netbird network: $NETBIRD_NETWORK"
    fi
fi

# ========================
# BASE SETUP
# ========================
apt update -y
apt install -y wireguard curl iptables jq qrencode ufw fail2ban unzip

# Create directories with proper permissions
mkdir -p "$DB_DIR" "$BACKUP_DIR"
chmod 750 "$DB_DIR"
chmod 755 "$BACKUP_DIR"
chown -R pos:pos "/home/pos/wireguard" 2>/dev/null || true

# Detect physical network interface (exclude virtual/docker interfaces)
IFACE=$(ip route | grep default | grep -v "docker\|br-\|veth\|netbird\|wg0\|wt0" | awk '{print $5}' | head -1)
echo "Detected physical interface: $IFACE"

# ========================
# FIREWALL SETUP (PRESERVE NETBIRD)
# ========================
if [ "$NETBIRD_ACTIVE" = true ]; then
    echo "Netbird detected - preserving existing UFW rules"
    # Don't reset, just ensure UFW is enabled
    ufw status > /dev/null 2>&1 || ufw --force enable
else
    ufw --force reset
fi

# Configure UFW
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow "$WG_PORT"/udp
ufw allow "$XRAY_PORT"/tcp

# Critical: Fix UFW forwarding policy (required for WireGuard RX)
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw
ufw --force enable

# ========================
# IP FORWARDING
# ========================
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi
sysctl -p 2>/dev/null || echo "✓ IP forwarding enabled"

# ========================
# WIREGUARD SETUP (WITH NETBIRD COMPATIBILITY)
# ========================
# Remove old config if exists
rm -f /etc/wireguard/wg0.conf 2>/dev/null

wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)
SERVER_PUB=$(cat /etc/wireguard/server_public.key)

# Build WireGuard config with Netbird compatibility
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = ${WG_SUBNET%.*}.1/24
ListenPort = $WG_PORT
MTU = 1420

# Ensure IP forwarding
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = sysctl -w net.ipv6.conf.all.forwarding=1

# Basic iptables rules for WireGuard
PostUp = iptables -P FORWARD ACCEPT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT

# NAT/MASQUERADE for internet access
PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE

EOF

# Add Netbird-specific rules if detected
if [ "$NETBIRD_ACTIVE" = true ] && [ -n "$NETBIRD_INTERFACE" ]; then
    cat >> /etc/wireguard/wg0.conf <<EOF
# Netbird Docker compatibility rules
PostUp = iptables -A FORWARD -i wg0 -o $NETBIRD_INTERFACE -j ACCEPT
PostUp = iptables -A FORWARD -i $NETBIRD_INTERFACE -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $NETBIRD_INTERFACE -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -o $NETBIRD_INTERFACE -j ACCEPT
PostDown = iptables -D FORWARD -i $NETBIRD_INTERFACE -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $NETBIRD_INTERFACE -j MASQUERADE
EOF
    echo "✓ Added Netbird Docker compatibility rules"
fi

# Add cleanup rules
cat >> /etc/wireguard/wg0.conf <<EOF
# Cleanup rules
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
EOF

# Start WireGuard
systemctl enable wg-quick@wg0
systemctl stop wg-quick@wg0 2>/dev/null
systemctl start wg-quick@wg0

# Wait for interface
sleep 3

# Verify and fix iptables rules if needed
if systemctl is-active --quiet wg-quick@wg0; then
    echo "✓ WireGuard is running"
    
    # Double-check iptables rules
    if ! iptables -L FORWARD -n 2>/dev/null | grep -q "wg0.*ACCEPT"; then
        iptables -A FORWARD -i wg0 -j ACCEPT
        iptables -A FORWARD -o wg0 -j ACCEPT
    fi
    
    if ! iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE.*$IFACE"; then
        iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
    fi
    
    # Show WireGuard status
    wg show
else
    echo "⚠️ WireGuard failed to start, checking logs..."
    journalctl -u wg-quick@wg0 -n 10 --no-pager
fi

# ========================
# XRAY INSTALL
# ========================
bash -c "$(curl -sL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" install

# Generate XRAY keys
KEYS=$(/usr/local/bin/xray x25519)
XRAY_PRIV=$(echo "$KEYS" | grep Private | awk '{print $3}')
XRAY_PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')

# Save keys with proper permissions
echo "$XRAY_PUB" > "$DB_DIR/xray_public.key"
echo "$XRAY_PRIV" > "$DB_DIR/xray_private.key"
chmod 600 "$DB_DIR/xray_private.key"
chmod 644 "$DB_DIR/xray_public.key"

# ========================
# XRAY CONFIG
# ========================
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
            "www.sixthkendra.com",
            "www.google.com",
            "fonts.gstatic.com"
          ],
          "privateKey": "$XRAY_PRIV",
          "shortIds": ["6ba85179e30d4fc2"]
        },
        "grpcSettings": {
          "serviceName": "grpc",
          "multiMode": true
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

# Create log directory with proper permissions
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log

sleep 2
if id "xray" &>/dev/null; then
    chown -R xray:xray /var/log/xray 2>/dev/null || true
    chmod 750 /var/log/xray
fi

systemctl enable xray
systemctl restart xray

# ========================
# USER DATABASE
# ========================
touch "$DB_DIR/users.db"
chmod 644 "$DB_DIR/users.db"

# ========================
# CLI TOOL (WITH NETBIRD DOCKER SUPPORT)
# ========================
cat > /usr/local/bin/wgx <<'EOF'
#!/bin/bash

DB="/etc/wg-xray/users.db"
WG_CONF="/etc/wireguard/wg0.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
BACKUP_DIR="/home/pos/wireguard/wg-xray-backups"

# Check if running as root, if not use sudo
USE_SUDO=""
if [ "$EUID" -ne 0 ]; then
    USE_SUDO="sudo"
fi

# Colors for output
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

get_next_ip() {
    if [ ! -f "$DB" ]; then
        echo "120.76.0.2"
        return
    fi
    LAST=$(awk -F',' '{print $3}' "$DB" 2>/dev/null | awk -F'.' '{print $4}' | sort -n | tail -1)
    if [ -z "$LAST" ] || [ "$LAST" -lt 2 ]; then
        echo "120.76.0.2"
    else
        echo "120.76.0.$((LAST+1))"
    fi
}

backup_configs() {
    NAME=$1
    [ -z "$NAME" ] && NAME="manual"
    FILE="$BACKUP_DIR/backup_${NAME}.tar.gz"
    mkdir -p "$BACKUP_DIR"
    $USE_SUDO tar -czf "$FILE" "$WG_CONF" "$XRAY_CONF" "$DB" 2>/dev/null || true
    log "Backup: $FILE"
    $USE_SUDO ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
}

sync_xray() {
    if [ ! -f "$DB" ]; then
        $USE_SUDO touch "$DB"
        $USE_SUDO chmod 644 "$DB"
    fi
    
    CLIENTS=$(awk -F',' '{printf "{\"id\":\"%s\",\"flow\":\"xtls-rprx-vision\"},",$2}' "$DB" 2>/dev/null | sed 's/,$//')
    
    if [ -z "$CLIENTS" ]; then
        CLIENTS=""
    fi
    
    $USE_SUDO jq ".inbounds[0].settings.clients = [ $CLIENTS ]" "$XRAY_CONF" > /tmp/xray.json
    $USE_SUDO mv /tmp/xray.json "$XRAY_CONF"
    
    $USE_SUDO systemctl restart xray
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
    
    XRAY_LINK="vless://$UUID@$SERVER_IP:10000?type=grpc&security=reality&serviceName=grpc&pbk=$PUB_KEY&sni=www.google.com&flow=xtls-rprx-vision#$USER"
    
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
    
    # Add WireGuard peer
    $USE_SUDO bash -c "cat >> \"$WG_CONF\" <<EOC

[Peer]
PublicKey = $PUB
AllowedIPs = $IP/32
EOC"
    
    $USE_SUDO systemctl restart wg-quick@wg0
    
    SERVER_IP=$(curl -s ifconfig.me)
    SERVER_PUB=$($USE_SUDO cat /etc/wireguard/server_public.key)
    
    mkdir -p "$BACKUP_DIR"
    cat > "$BACKUP_DIR/wg-$USER.conf" <<EOC
[Interface]
PrivateKey = $PRIV
Address = $IP/24
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:21821
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOC
    
    sync_xray
    backup_configs "$USER"
    
    echo ""
    echo -e "${GREEN}=== USER CREATED ===${NC}"
    echo "Username: $USER"
    echo "IP: $IP"
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
    
    while IFS=',' read -r u uuid ip pub; do
        [ -z "$u" ] && continue
        echo "" >> "$TMP"
        echo "[Peer]" >> "$TMP"
        echo "PublicKey = $pub" >> "$TMP"
        echo "AllowedIPs = $ip/32" >> "$TMP"
    done < "$DB"
    
    $USE_SUDO mv "$TMP" "$WG_CONF"
    
    $USE_SUDO systemctl restart wg-quick@wg0
    sync_xray
    
    rm -f "$BACKUP_DIR/wg-$USER.conf" "$BACKUP_DIR/$USER-xray-link.txt" 2>/dev/null
    
    echo -e "${GREEN}User removed: $USER${NC}"
}

list_users() {
    if [ ! -f "$DB" ] || [ ! -s "$DB" ]; then
        echo "No users found"
        return
    fi
    
    printf "%-20s %-36s %-15s\n" "USERNAME" "UUID" "IP"
    echo "--------------------------------------------------------------------------------"
    
    while IFS=',' read -r user uuid ip pub; do
        printf "%-20s %-36s %-15s\n" "$user" "$uuid" "$ip"
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
    
    IFS=',' read -r user uuid ip pub <<< "$line"
    
    echo -e "${GREEN}User Details:${NC}"
    echo "Username: $user"
    echo "UUID: $uuid"
    echo "IP: $ip"
    
    if [ -f "$BACKUP_DIR/wg-$user.conf" ]; then
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
        echo "  add USERNAME     - Add new user"
        echo "  remove USERNAME  - Remove user"
        echo "  list             - List all users"
        echo "  show USERNAME    - Show user details and QR codes"
        echo "  backup           - Create configuration backup"
        ;;
esac
EOF

chmod +x /usr/local/bin/wgx

# Add pos user to sudoers for wgx commands
echo "pos ALL=(ALL) NOPASSWD: /usr/local/bin/wgx" >> /etc/sudoers.d/wgx
chmod 440 /etc/sudoers.d/wgx

# ========================
# SYSTEM OPTIMIZATION (LXC/DOCKER FRIENDLY)
# ========================
cat >> /etc/sysctl.conf <<EOF
# Network optimization (safe for containers)
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
EOF

sysctl -p 2>/dev/null || echo "✓ sysctl settings applied"

# Save iptables rules
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    apt install -y iptables-persistent
    netfilter-persistent save
fi

# ========================
# VERIFICATION
# ========================
echo ""
echo "=== VERIFICATION ==="
echo -n "WireGuard: "
systemctl is-active wg-quick@wg0 && echo "✓ Running" || echo "✗ Failed"

echo -n "Xray: "
systemctl is-active xray && echo "✓ Running" || echo "✗ Failed"

if [ "$NETBIRD_ACTIVE" = true ]; then
    echo -n "Netbird Docker: "
    docker ps --format "table {{.Names}}" 2>/dev/null | grep -q netbird && echo "✓ Running" || echo "⚠️ Not detected"
    echo -n "Netbird Interface: "
    ip link show | grep -q "netbird\|wt0" && echo "✓ Present" || echo "⚠️ Not found"
fi

echo ""
echo "WireGuard Interface Status:"
wg show 2>/dev/null || echo "  No peers yet"

echo ""
echo "Firewall Forward Policy:"
grep DEFAULT_FORWARD_POLICY /etc/default/ufw

# ========================
# DONE
# ========================
SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "=== INSTALL COMPLETE ==="
echo "Server IP: $SERVER_IP"
echo "WireGuard Port: $WG_PORT (Netbird uses 51820 - no conflict)"
echo "XRAY Port: $XRAY_PORT"
echo ""
echo "Commands (run as pos user):"
echo "  wgx add username     - Add new user"
echo "  wgx list             - List all users"
echo "  wgx show username    - Show user details and QR codes"
echo "  wgx remove username  - Remove user"
echo ""
echo "Configuration files:"
echo "  WireGuard: /etc/wireguard/wg0.conf"
echo "  XRAY: /usr/local/etc/xray/config.json"
echo "  Users DB: /etc/wg-xray/users.db"
echo "  Backups: $BACKUP_DIR"
echo ""
if [ "$NETBIRD_ACTIVE" = true ]; then
    echo "⚠️  Netbird Docker Container Detected:"
    echo "   • WireGuard uses port $WG_PORT (different from Netbird's 51820)"
    echo "   • Both VPNs can run simultaneously"
    echo "   • Traffic can route between WireGuard and Netbird if needed"
    echo ""
    echo "To check Netbird status:"
    echo "  docker ps | grep netbird"
    echo "  docker logs netbird"
fi