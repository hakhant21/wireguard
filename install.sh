#!/bin/bash

set -e

echo "=== Wireguard + Xray Server Installer ==="

# Configuration variables
WG_PORT=51820
XRAY_PORT=10000
WG_SUBNET="100.76.0.0/24"
WG_NETWORK="100.76.0"
DB_DIR="/etc/wg-xray"
BACKUP_DIR="/root/wireguard/wg-xray-backups"

# ========================
# BASE SETUP
# ========================
apt update -y
apt install -y wireguard curl iptables jq qrencode ufw fail2ban

# Create directories with proper permissions
mkdir -p "$DB_DIR" "$BACKUP_DIR"
chmod 750 "$DB_DIR"

# Detect network interface
IFACE=$(ip route | grep default | awk '{print $5}')
echo "Detected interface: $IFACE"

# Configure firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow "$WG_PORT"/udp
ufw allow "$XRAY_PORT"/tcp
ufw --force enable

# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# ========================
# WIREGUARD SETUP
# ========================
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)
SERVER_PUB=$(cat /etc/wireguard/server_public.key)

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = ${WG_SUBNET%.*}.1/24
ListenPort = $WG_PORT

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
EOF

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# ========================
# XRAY INSTALL
# ========================
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

# Generate XRAY keys
KEYS=$(/usr/local/bin/xray x25519)
XRAY_PRIV=$(echo "$KEYS" | grep Private | awk '{print $3}')
XRAY_PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')

# Save keys with proper permissions
echo "$XRAY_PUB" > "$DB_DIR/xray_public.key"
echo "$XRAY_PRIV" > "$DB_DIR/xray_private.key"
chmod 600 "$DB_DIR/xray_private.key"

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

# Wait for Xray user to be created and set permissions
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
chmod 640 "$DB_DIR/users.db"

# ========================
# CLI TOOL (NO EXPIRATION) - COMMAND NAME: wgx
# ========================
cat > /usr/local/bin/wgx <<'EOF'
#!/bin/bash

DB="/etc/wg-xray/users.db"
WG_CONF="/etc/wireguard/wg0.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
BACKUP_DIR="/root/wireguard/wg-xray-backups"


# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

get_next_ip() {
    LAST=$(awk -F',' '{print $3}' "$DB" | awk -F'.' '{print $4}' | sort -n | tail -1)
    if [ -z "$LAST" ] || [ "$LAST" -lt 2 ]; then
        echo "100.76.0.2"
    else
        echo "100.76.0.$((LAST+1))"
    fi
}

backup_configs() {
    NAME=$1

    [ -z "$NAME" ] && NAME="manual"

    FILE="$BACKUP_DIR/backup_${NAME}.tar.gz"

    tar -czf "$FILE" "$WG_CONF" "$XRAY_CONF" "$DB" 2>/dev/null || true

    log "Backup: $FILE"

    ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
}w

sync_xray() {
    CLIENTS=$(awk -F',' '{printf "{\"id\":\"%s\",\"flow\":\"xtls-rprx-vision\"},",$2}' "$DB" | sed 's/,$//')

    if [ -z "$CLIENTS" ]; then
        CLIENTS=""
    fi

    jq ".inbounds[0].settings.clients = [ $CLIENTS ]" "$XRAY_CONF" > /tmp/xray.json
    mv /tmp/xray.json "$XRAY_CONF"

    systemctl restart xray
    log "XRAY configuration synced"
}

generate_qr() {
    USER=$1
    UUID=$2

    SERVER_IP=$(curl -s ifconfig.me)
    PUB_KEY=$(cat /etc/wg-xray/xray_public.key)

    XRAY_LINK="vless://$UUID@$SERVER_IP:10000?type=grpc&security=reality&serviceName=grpc&pbk=$PUB_KEY&sni=www.google.com&flow=xtls-rprx-vision#$USER"

    echo ""
    echo -e "${GREEN}===== XRAY LINK =====${NC}"
    echo "$XRAY_LINK"
    qrencode -t ansiutf8 "$XRAY_LINK" 2>/dev/null || echo "QR code generation failed"

    echo ""
    echo -e "${GREEN}===== WG QR =====${NC}"
    qrencode -t ansiutf8 < "$BACKUP_DIR/wg-$USER.conf" 2>/dev/null || echo "QR code generation failed"

    # Save configuration files
    cp "$BACKUP_DIR/wg-$USER.conf" "$BACKUP_DIR/" 2>/dev/null || true
    echo "$XRAY_LINK" > "$BACKUP_DIR/$USER-xray-link.txt"
}

add_user() {
    USER=$1

    if [ -z "$USER" ]; then
        error "Username required"
        echo "Usage: wgx add USERNAME"
        return 1
    fi

    # Check if user exists
    if grep -q "^$USER," "$DB"; then
        error "User $USER already exists"
        return 1
    fi

    IP=$(get_next_ip)

    wg genkey | tee /tmp/client.key | wg pubkey > /tmp/client.pub
    PRIV=$(cat /tmp/client.key)
    PUB=$(cat /tmp/client.pub)
    UUID=$(cat /proc/sys/kernel/random/uuid)

    echo "$USER,$UUID,$IP,$PUB" >> "$DB"

    # Add WireGuard peer
    cat >> "$WG_CONF" <<EOC

[Peer]
PublicKey = $PUB
AllowedIPs = $IP/32
EOC

    systemctl restart wg-quick@wg0

    SERVER_IP=$(curl -s ifconfig.me)
    SERVER_PUB=$(cat /etc/wireguard/server_public.key)

    # Client WG config
    cat > "$BACKUP_DIR/wg-$USER.conf" <<EOC
[Interface]
PrivateKey = $PRIV
Address = $IP/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_IP:51820
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

    line=$(grep "^$USER," "$DB")
    if [ -z "$line" ]; then
        error "User $USER not found"
        return 1
    fi

    PUB=$(echo "$line" | cut -d',' -f4)

    # Remove from DB
    sed -i "/^$USER,/d" "$DB"

    # Rebuild WireGuard config safely
    TMP=$(mktemp)

    # Keep Interface section
    awk '
    BEGIN {keep=1}
    /^$begin:math:display$Peer$end:math:display$/ {keep=0}
    keep {print}
    ' "$WG_CONF" > "$TMP"

    # Re-add all peers except removed one
    while IFS=',' read -r u uuid ip pub; do
        [ -z "$u" ] && continue

        echo "" >> "$TMP"
        echo "[Peer]" >> "$TMP"
        echo "PublicKey = $pub" >> "$TMP"
        echo "AllowedIPs = $ip/32" >> "$TMP"
    done < "$DB"

    mv "$TMP" "$WG_CONF"

    systemctl restart wg-quick@wg0
    sync_xray

    # Cleanup files
    rm -f "$BACKUP_DIR/wg-$USER.conf" "$BACKUP_DIR/$USER-xray-link.txt" "$BACKUP_DIR/backup_$USER.tar.gz" 2>/dev/null

    echo -e "${GREEN}User removed: $USER${NC}"
}

list_users() {
    if [ ! -s "$DB" ]; then
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

# ========================
# SYSTEM OPTIMIZATION
# ========================
cat >> /etc/sysctl.conf <<EOF
# Network optimization
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_default=262144
net.core.wmem_default=262144
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
EOF

sysctl -p

# ========================
# DONE
# ========================
SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "=== INSTALL COMPLETE ==="
echo "Server IP: $SERVER_IP"
echo "WireGuard Port: $WG_PORT"
echo "XRAY Port: $XRAY_PORT"
echo ""
echo "Commands:"
echo "  wgx add username     - Add new user"
echo "  wgx list             - List all users"
echo "  wgx show username    - Show user details and QR codes"
echo "  wgx remove username  - Remove user"
echo "  wgx backup username  - Backup configurations"
echo ""
echo "Configuration files:"
echo "  WireGuard: /etc/wireguard/wg0.conf"
echo "  XRAY: /usr/local/etc/xray/config.json"
echo "  Users DB: /etc/wg-xray/users.db"
echo "  Backups: $BACKUP_DIR"
