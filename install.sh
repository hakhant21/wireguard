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

# ========================
# DETECT LXC ENVIRONMENT
# ========================
IS_LXC=false
if [ -f /proc/1/environ ] && grep -q "container=lxc" /proc/1/environ 2>/dev/null; then
    IS_LXC=true
    echo "✓ LXC container detected"
fi

# ========================
# FIX: Get the ACTUAL outbound interface that reaches internet
# ========================
# For LXC, the interface that routes to 8.8.8.8 is the correct one
IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
if [ -z "$IFACE" ]; then
    IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
fi
echo "Detected outbound interface: $IFACE"

# ========================
# FIX: Disable rp_filter for WireGuard in LXC
# ========================
if [ "$IS_LXC" = true ]; then
    echo "=== Applying LXC-specific fixes ==="
    
    # Disable strict reverse path filtering (critical for WG RX)
    sysctl -w net.ipv4.conf.all.rp_filter=2
    sysctl -w net.ipv4.conf.default.rp_filter=2
    sysctl -w net.ipv4.conf.$IFACE.rp_filter=2
    
    # Make persistent
    cat >> /etc/sysctl.conf <<EOF
# WireGuard LXC fixes
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.$IFACE.rp_filter=2
EOF
    
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
apt update -y
apt install -y wireguard curl iptables jq qrencode ufw fail2ban unzip

# Create directories
mkdir -p "$DB_DIR" "$BACKUP_DIR"
chmod 750 "$DB_DIR"
chmod 755 "$BACKUP_DIR"

# ========================
# FIREWALL SETUP (Preserve existing)
# ========================
if ! ufw status | grep -q "Status: active"; then
    ufw --force enable
fi

ufw default deny incoming
ufw default allow outgoing

# Add rules without resetting
ufw allow ssh
ufw allow "$WG_PORT"/udp
ufw allow "$XRAY_PORT"/tcp

# Fix UFW forwarding policy
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw 2>/dev/null || true
ufw --force reload

# ========================
# IP FORWARDING
# ========================
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf; then
    echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
fi

# ========================
# WIREGUARD SETUP - FIXED POST RULES
# ========================
rm -f /etc/wireguard/wg0.conf 2>/dev/null

wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)
SERVER_PUB=$(cat /etc/wireguard/server_public.key)

# Create WireGuard config with CORRECT PostUp/PostDown rules
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = ${WG_SUBNET%.*}.1/24
ListenPort = $WG_PORT
MTU = 1420

# Critical: Masquerade on the CORRECT outbound interface
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = sysctl -w net.ipv6.conf.all.forwarding=1
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

systemctl enable wg-quick@wg0
systemctl stop wg-quick@wg0 2>/dev/null || true
systemctl start wg-quick@wg0

sleep 3

if systemctl is-active --quiet wg-quick@wg0; then
    echo "✓ WireGuard running"
else
    echo "⚠️ WireGuard failed to start"
    journalctl -u wg-quick@wg0 -n 10 --no-pager
    exit 1
fi

# ========================
# XRAY INSTALL (Unchanged)
# ========================
bash -c "$(curl -sL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" install

KEYS=$(/usr/local/bin/xray x25519)
XRAY_PRIV=$(echo "$KEYS" | grep Private | awk '{print $3}')
XRAY_PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')

echo "$XRAY_PUB" > "$DB_DIR/xray_public.key"
echo "$XRAY_PRIV" > "$DB_DIR/xray_private.key"
chmod 600 "$DB_DIR/xray_private.key"
chmod 644 "$DB_DIR/xray_public.key"

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

mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
XRAY_SERVICE_USER=$(systemctl show -p User --value xray 2>/dev/null || true)
XRAY_SERVICE_GROUP=$(systemctl show -p Group --value xray 2>/dev/null || true)

if [ -z "$XRAY_SERVICE_USER" ]; then
    XRAY_SERVICE_USER="xray"
fi
if [ -z "$XRAY_SERVICE_GROUP" ]; then
    XRAY_SERVICE_GROUP="$XRAY_SERVICE_USER"
fi

if ! id "$XRAY_SERVICE_USER" >/dev/null 2>&1; then
    XRAY_SERVICE_USER="nobody"
    XRAY_SERVICE_GROUP=$(id -gn nobody 2>/dev/null || echo "nobody")
fi

chown -R "$XRAY_SERVICE_USER:$XRAY_SERVICE_GROUP" /var/log/xray 2>/dev/null || true
chmod 750 /var/log/xray
chmod 640 /var/log/xray/access.log /var/log/xray/error.log

systemctl enable xray
systemctl restart xray

# ========================
# USER DATABASE & CLI TOOL
# ========================
touch "$DB_DIR/users.db"
chmod 644 "$DB_DIR/users.db"

echo "$(date)" > "$DB_DIR/.installed"

# ========================
# CLI TOOL - FIXED MTU
# ========================
cat > /usr/local/bin/wgx <<'EOF'
#!/bin/bash

DB="/etc/wg-xray/users.db"
WG_CONF="/etc/wireguard/wg0.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
BACKUP_DIR="/root/wireguard/wg-xray-backups"

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
    $USE_SUDO mkdir -p "$BACKUP_DIR"
    $USE_SUDO tar -czf "$FILE" "$WG_CONF" "$XRAY_CONF" "$DB" 2>/dev/null || true
    log "Backup: $FILE"
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
    
    $USE_SUDO bash -c "cat >> \"$WG_CONF\" <<EOC

[Peer]
PublicKey = $PUB
AllowedIPs = $IP/32
EOC"
    
    $USE_SUDO systemctl restart wg-quick@wg0
    
    SERVER_IP=$(curl -s ifconfig.me)
    SERVER_PUB=$($USE_SUDO cat /etc/wireguard/server_public.key)
    
    $USE_SUDO mkdir -p "$BACKUP_DIR"
    # FIX: Set MTU to 1420 to match server
    $USE_SUDO tee "$BACKUP_DIR/wg-$USER.conf" > /dev/null <<EOC
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
    
    $USE_SUDO rm -f "$BACKUP_DIR/wg-$USER.conf" "$BACKUP_DIR/$USER-xray-link.txt" 2>/dev/null
    
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

# Add invoking user to sudoers (when installer was run with sudo)
if [ "$WGX_OWNER" != "root" ]; then
    echo "$WGX_OWNER ALL=(ALL) NOPASSWD: /usr/local/bin/wgx" > /etc/sudoers.d/wgx
    chmod 440 /etc/sudoers.d/wgx
fi

# ========================
# CREATE UNINSTALL SCRIPT
# ========================
cat > "$UNINSTALL_SCRIPT" <<'EOF'
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
rm -rf /var/log/xray
rm -rf /etc/wg-xray
rm -rf /root/wireguard/wg-xray-backups
rm -f /usr/local/bin/wgx
rm -f /etc/sudoers.d/wgx

# Clean iptables
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null

echo "=== Uninstall Complete ==="
EOF

chmod +x "$UNINSTALL_SCRIPT"

# Save iptables
apt install -y iptables-persistent 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

# ========================
# VERIFICATION
# ========================
echo ""
echo "=== VERIFICATION ==="
systemctl is-active wg-quick@wg0 && echo "✓ WireGuard: Running" || echo "✗ WireGuard: Failed"
systemctl is-active xray && echo "✓ Xray: Running" || echo "✗ Xray: Failed"

if [ "$NETBIRD_ACTIVE" = true ]; then
    docker ps --format "table {{.Names}}" 2>/dev/null | grep -q netbird && echo "✓ Netbird: Running" || echo "⚠️ Netbird: Not detected"
fi

echo ""
echo "WireGuard peers:"
wg show

SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "=== INSTALL COMPLETE (LXC Optimized) ==="
echo "Server IP: $SERVER_IP"
echo "WireGuard Port: $WG_PORT"
echo "XRAY Port: $XRAY_PORT"
echo ""
echo "Commands:"
echo "  wgx add username    - Add user"
echo "  wgx list            - List users"
echo "  wgx show username   - Show QR codes"
echo ""
echo "To uninstall: sudo wgx-uninstall"
