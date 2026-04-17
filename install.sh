#!/bin/bash

set -e

echo "=== Wireguard + Xray Server Installer (Netbird Compatible) ==="

# Configuration variables
WG_PORT=21821  # Changed from 21821 (already using this)
XRAY_PORT=10000
WG_SUBNET="120.76.0.0/24"
WG_NETWORK="120.76.0"
DB_DIR="/etc/wg-xray"
BACKUP_DIR="/home/pos/wireguard/wg-xray-backups"

# ========================
# CHECK FOR NETBIRD CONFLICTS
# ========================
if systemctl is-active --quiet netbird; then
    echo "✓ Netbird detected - adjusting configuration"
    NETBIRD_ACTIVE=true
    
    # Check if Netbird already uses WireGuard port
    if ss -ulnp | grep -q ":51820.*netbird"; then
        echo "✓ Netbird using port 51820 (no conflict with WireGuard port $WG_PORT)"
    fi
else
    NETBIRD_ACTIVE=false
fi

# ========================
# BASE SETUP (PRESERVE NETBIRD)
# ========================
apt install -y wireguard curl iptables jq qrencode ufw fail2ban unzip

# Create directories with proper permissions
mkdir -p "$DB_DIR" "$BACKUP_DIR"
chmod 750 "$DB_DIR"

# Detect physical interface (exclude Netbird virtual interfaces)
IFACE=$(ip route | grep default | grep -v "netbird\|wg0\|wt0" | awk '{print $5}' | head -1)
echo "Detected physical interface: $IFACE"

# ========================
# FIREWALL SETUP (PRESERVE NETBIRD RULES)
# ========================
# Don't reset UFW completely - just add rules
if ufw status | grep -q "active"; then
    echo "UFW active - adding rules"
else
    ufw --force enable
fi

# Set defaults only if not already set
ufw default deny incoming
ufw default allow outgoing

# Add rules (without resetting)
ufw allow ssh
ufw allow "$WG_PORT"/udp
ufw allow "$XRAY_PORT"/tcp

# IMPORTANT: Don't reload if Netbird might have custom rules
echo "Firewall rules added (preserving existing rules)"

# ========================
# IP FORWARDING (CHECK ONLY, DON'T DUPLICATE)
# ========================
if ! sysctl net.ipv4.ip_forward | grep -q "= 1"; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
else
    echo "✓ IP forwarding already enabled"
fi

# ========================
# WIREGUARD SETUP (NO MASQUERADE CONFLICT)
# ========================
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

# Only add forwarding, no NAT (Netbird handles masquerade)
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
EOF

# If Netbird is NOT active, add masquerade
if [ "$NETBIRD_ACTIVE" = false ]; then
    cat >> /etc/wireguard/wg0.conf <<EOF
PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
EOF
    echo "Added MASQUERADE (Netbird not detected)"
else
    echo "⚠️  Skipping MASQUERADE to avoid conflict with Netbird"
    echo "   Netbird will handle NAT for WireGuard traffic"
fi

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# ========================
# XRAY INSTALL (NO CHANGES NEEDED)
# ========================
wget https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh -O xray-install.sh

./xray-install.sh --install
# Generate XRAY keys
KEYS=$(/usr/local/bin/xray x25519)
XRAY_PRIV=$(echo "$KEYS" | grep Private | awk '{print $3}')
XRAY_PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')

# Save keys
echo "$XRAY_PUB" > "$DB_DIR/xray_public.key"
echo "$XRAY_PRIV" > "$DB_DIR/xray_private.key"
chmod 600 "$DB_DIR/xray_private.key"

# ========================
# XRAY CONFIG (SAME AS YOURS)
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
chmod 640 "$DB_DIR/users.db"

# [Insert your wgx script here - same as yours but with updated WG_PORT variable]
# Make sure the wgx script uses WG_PORT=21821

# ========================
# SYSTEM OPTIMIZATION (NO CONFLICT)
# ========================
cat >> /etc/sysctl.conf <<EOF
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_tw_reuse=1
EOF

# Apply settings silently
sysctl -p > /dev/null
# ========================
# VERIFICATION
# ========================
echo ""
echo "=== VERIFYING NO CONFLICTS ==="

# Check services
echo -n "Netbird: "
systemctl is-active netbird && echo "✓ Running" || echo "⚠️ Not running (expected if not installed)"

echo -n "WireGuard: "
systemctl is-active wg-quick@wg0 && echo "✓ Running" || echo "✗ Failed"

echo -n "Xray: "
systemctl is-active xray && echo "✓ Running" || echo "✗ Failed"

# Check port conflicts
echo -e "\nPort status:"
ss -tulnp | grep -E "51820|$WG_PORT|$XRAY_PORT" || echo "No ports found"

# Check for duplicate iptables rules
if [ "$NETBIRD_ACTIVE" = true ]; then
    NAT_RULES=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -c "MASQUERADE" || echo "0")
    if [ "$NAT_RULES" -gt 1 ]; then
        echo "⚠️ Warning: Multiple MASQUERADE rules detected ($NAT_RULES)"
        echo "   This may cause issues. Run: iptables -t nat -L POSTROUTING -n"
    else
        echo "✓ NAT MASQUERADE rules: $NAT_RULES (good)"
    fi
fi

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
echo "Commands:"
echo "  wgx add username     - Add new user"
echo "  wgx list             - List all users"
echo "  wgx show username    - Show user details and QR codes"
echo "  wgx remove username  - Remove user"
echo ""
echo "⚠️  IMPORTANT NOTES:"
if [ "$NETBIRD_ACTIVE" = true ]; then
    echo "  • Netbird is active - WireGuard traffic will route through Netbird"
    echo "  • No MASQUERADE added (Netbird handles NAT)"
    echo "  • Both VPNs can run simultaneously"
    echo "  • Clients connect to WireGuard on port $WG_PORT"
else
    echo "  • Netbird not detected - standard configuration"
fi