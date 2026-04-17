#!/bin/bash

set -e

echo "=== Wireguard + Xray Server Installer (Netbird Docker Compatible) ==="

# Configuration variables
WG_PORT=21821
XRAY_PORT=10000
WG_SUBNET="120.76.0.0/24"
WG_NETWORK="120.76.0"
WG_SUBNET="120.76.0.0/24"
WG_NETWORK="120.76.0"
DB_DIR="/etc/wg-xray"
BACKUP_DIR="/home/pos/wireguard/wg-xray-backups"
UNINSTALL_SCRIPT="/usr/local/bin/wgx-uninstall"

# ========================
# CHECK FOR EXISTING INSTALLATION
# ========================
if [ -f "$DB_DIR/.installed" ]; then
    echo "⚠️ Existing installation detected!"
    echo "To uninstall, run: sudo wgx-uninstall"
    echo "Or continue with reinstall (will backup old config)"
    read -p "Continue with reinstall? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    # Backup old installation
    BACKUP_FILE="/tmp/wg-xray-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$BACKUP_FILE" "$DB_DIR" /etc/wireguard /usr/local/etc/xray 2>/dev/null || true
    echo "✓ Old configuration backed up to $BACKUP_FILE"
fi

# ========================
# DETECT NETBIRD IN DOCKER
# ========================
NETBIRD_ACTIVE=false
NETBIRD_INTERFACE=""
NETBIRD_NETWORK=""

if docker ps --format "table {{.Names}}" 2>/dev/null | grep -q "netbird"; then
    echo "✓ Netbird Docker container detected"
    NETBIRD_ACTIVE=true
    
    if ip link show | grep -q "netbird"; then
        NETBIRD_INTERFACE="netbird"
    elif ip link show | grep -q "wt0"; then
        NETBIRD_INTERFACE="wt0"
    fi
    
    if [ -n "$NETBIRD_INTERFACE" ]; then
        NETBIRD_NETWORK=$(ip addr show $NETBIRD_INTERFACE 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
        echo "✓ Netbird interface: $NETBIRD_INTERFACE"
    fi
fi

# ========================
# CHECK FOR NETBIRD CONFLICTS
# ========================
apt update -y
apt install -y wireguard curl iptables jq qrencode ufw fail2ban unzip

# Create directories with proper permissions
mkdir -p "$DB_DIR" "$BACKUP_DIR"
chmod 750 "$DB_DIR"
chmod 755 "$BACKUP_DIR"
chown -R pos:pos "/home/pos/wireguard" 2>/dev/null || true

# Detect physical network interface
IFACE=$(ip route | grep default | grep -v "docker\|br-\|veth\|netbird\|wg0\|wt0" | awk '{print $5}' | head -1)
echo "Detected physical interface: $IFACE"

# ========================
# FIREWALL SETUP
# ========================
if [ "$NETBIRD_ACTIVE" = true ]; then
    echo "Netbird detected - preserving existing UFW rules"
    ufw status > /dev/null 2>&1 || ufw --force enable
else
    ufw --force reset
fi

ufw default deny incoming
ufw default allow outgoing

# Add rules (without resetting)
ufw allow ssh
ufw allow "$WG_PORT"/udp
ufw allow "$XRAY_PORT"/tcp

# Fix UFW forwarding policy
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
# WIREGUARD SETUP (NO MASQUERADE CONFLICT)
# ========================
rm -f /etc/wireguard/wg0.conf 2>/dev/null

wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

SERVER_PRIV=$(cat /etc/wireguard/server_private.key)
SERVER_PUB=$(cat /etc/wireguard/server_public.key)

# Create WireGuard config WITHOUT MASQUERADE (Netbird handles this)
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $SERVER_PRIV
Address = ${WG_SUBNET%.*}.1/24
ListenPort = $WG_PORT
MTU = 1420

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = sysctl -w net.ipv6.conf.all.forwarding=1
PostUp = iptables -P FORWARD ACCEPT
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp = iptables -A FORWARD -i wg0 -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE

EOF

if [ "$NETBIRD_ACTIVE" = true ] && [ -n "$NETBIRD_INTERFACE" ]; then
    cat >> /etc/wireguard/wg0.conf <<EOF
PostUp = iptables -A FORWARD -i wg0 -o $NETBIRD_INTERFACE -j ACCEPT
PostUp = iptables -A FORWARD -i $NETBIRD_INTERFACE -o wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $NETBIRD_INTERFACE -j MASQUERADE

PostDown = iptables -D FORWARD -i wg0 -o $NETBIRD_INTERFACE -j ACCEPT
PostDown = iptables -D FORWARD -i $NETBIRD_INTERFACE -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $NETBIRD_INTERFACE -j MASQUERADE
EOF
fi

cat >> /etc/wireguard/wg0.conf <<EOF
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
EOF

systemctl enable wg-quick@wg0
systemctl stop wg-quick@wg0 2>/dev/null
systemctl start wg-quick@wg0

sleep 3

if systemctl is-active --quiet wg-quick@wg0; then
    echo "✓ WireGuard running"
else
    echo "⚠️ WireGuard failed to start"
    journalctl -u wg-quick@wg0 -n 5 --no-pager
fi

# ========================
# XRAY INSTALL
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
# USER DATABASE & CLI TOOL
# ========================
touch "$DB_DIR/users.db"
chmod 644 "$DB_DIR/users.db"

# Mark as installed
echo "$(date)" > "$DB_DIR/.installed"

# ========================
# CLI TOOL
# ========================
cat > /usr/local/bin/wgx <<'EOF'
#!/bin/bash

DB="/etc/wg-xray/users.db"
WG_CONF="/etc/wireguard/wg0.conf"
XRAY_CONF="/usr/local/etc/xray/config.json"
BACKUP_DIR="/home/pos/wireguard/wg-xray-backups"

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
    mkdir -p "$BACKUP_DIR"
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
    
    mkdir -p "$BACKUP_DIR"
    cat > "$BACKUP_DIR/wg-$USER.conf" <<EOC
[Interface]
PrivateKey = $PRIV
Address = $IP/24
DNS = 1.1.1.1, 8.8.8.8
MTU = 1300

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

# Add pos user to sudoers
echo "pos ALL=(ALL) NOPASSWD: /usr/local/bin/wgx" >> /etc/sudoers.d/wgx
chmod 440 /etc/sudoers.d/wgx

# ========================
# CREATE UNINSTALL SCRIPT
# ========================
cat > "$UNINSTALL_SCRIPT" <<'EOF'
#!/bin/bash

echo "=== WireGuard + Xray Uninstaller ==="
echo ""
echo "This will remove:"
echo "  • WireGuard configuration"
echo "  • Xray configuration"
echo "  • User database"
echo "  • Firewall rules"
echo "  • iptables rules"
echo ""
echo "Netbird Docker container will NOT be affected."
echo ""
read -p "Are you sure? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""
echo "=== Creating backup ==="
BACKUP_FILE="/tmp/wg-xray-final-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$BACKUP_FILE" /etc/wireguard /usr/local/etc/xray /etc/wg-xray 2>/dev/null || true
echo "✓ Backup saved to $BACKUP_FILE"

echo ""
echo "=== Stopping services ==="
systemctl stop wg-quick@wg0 2>/dev/null && echo "✓ WireGuard stopped"
systemctl stop xray 2>/dev/null && echo "✓ Xray stopped"
systemctl disable wg-quick@wg0 2>/dev/null
systemctl disable xray 2>/dev/null

echo ""
echo "=== Removing WireGuard ==="
ip link del wg0 2>/dev/null && echo "✓ WireGuard interface removed"
rm -rf /etc/wireguard 2>/dev/null && echo "✓ WireGuard config removed"

echo ""
echo "=== Removing Xray ==="
bash -c "$(curl -sL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)" remove 2>/dev/null || true
rm -rf /usr/local/etc/xray 2>/dev/null
rm -rf /var/log/xray 2>/dev/null
rm -f /usr/local/bin/xray 2>/dev/null
echo "✓ Xray removed"

echo ""
echo "=== Removing configuration files ==="
rm -rf /etc/wg-xray 2>/dev/null && echo "✓ User database removed"
rm -rf /home/pos/wireguard/wg-xray-backups 2>/dev/null && echo "✓ Backups removed"
rm -f /usr/local/bin/wgx 2>/dev/null && echo "✓ wgx command removed"
rm -f /etc/sudoers.d/wgx 2>/dev/null

echo ""
echo "=== Cleaning iptables rules ==="
# Remove WireGuard related iptables rules
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i wg0 -o wg0 -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o wg0 -j MASQUERADE 2>/dev/null

# Remove Netbird related rules if they exist
iptables -D FORWARD -i wg0 -o netbird -j ACCEPT 2>/dev/null
iptables -D FORWARD -i netbird -o wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i wg0 -o wt0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -i wt0 -o wg0 -j ACCEPT 2>/dev/null

echo "✓ iptables rules cleaned"

echo ""
echo "=== Restoring UFW defaults ==="
ufw --force reset 2>/dev/null || true
ufw default deny incoming 2>/dev/null
ufw default allow outgoing 2>/dev/null
ufw allow ssh 2>/dev/null
ufw --force enable 2>/dev/null || true
echo "✓ UFW reset to defaults (SSH allowed)"

echo ""
echo "=== Removing sysctl additions ==="
sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
sed -i '/net.ipv6.conf.all.forwarding=1/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_rmem=4096 87380 16777216/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_wmem=4096 65536 16777216/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_syncookies=1/d' /etc/sysctl.conf
sed -i '/net.ipv4.tcp_tw_reuse=1/d' /etc/sysctl.conf
echo "✓ sysctl cleaned"

echo ""
echo "=== Uninstall Complete ==="
echo ""
echo "WireGuard and Xray have been removed."
echo "Netbird Docker container was NOT affected."
echo ""
echo "Backup saved to: $BACKUP_FILE"
echo ""
echo "To reinstall, run the original installer script."
EOF

chmod +x "$UNINSTALL_SCRIPT"

# ========================
# SYSTEM OPTIMIZATION (NO CONFLICT)
# ========================
cat >> /etc/sysctl.conf <<EOF
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
fi

echo ""
echo "WireGuard Interface Status:"
wg show 2>/dev/null || echo "  No peers yet"

# ========================
# DONE
# ========================
SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "=== INSTALL COMPLETE (Netbird Compatible) ==="
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
echo "To UNINSTALL everything:"
echo "  sudo wgx-uninstall"
echo ""
echo "Configuration files:"
echo "  WireGuard: /etc/wireguard/wg0.conf"
echo "  XRAY: /usr/local/etc/xray/config.json"
echo "  Users DB: /etc/wg-xray/users.db"
echo "  Backups: $BACKUP_DIR"
echo "  Uninstaller: $UNINSTALL_SCRIPT"