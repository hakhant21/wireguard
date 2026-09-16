#!/usr/bin/env bash
#
# wg-xray-installer.sh
# WireGuard + Xray (VLESS Reality/gRPC) installer for LXC/VPS
# Stable-performance refactor
#
set -Eeuo pipefail

# ============================================================================
# GLOBALS
# ============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly INSTALL_LOG="/var/log/wgx-install.log"

# Defaults (overridable via prompts)
WG_PORT="21821"
XRAY_PORT="10000"
WG_SUBNET="10.76.0.0/24"
WG_NETWORK="10.76.0"
WG_MTU="1420"
DB_DIR="/etc/wg-xray"
BACKUP_DIR="/root/wireguard/wg-xray-backups"
UNINSTALL_SCRIPT="/usr/local/bin/wgx-uninstall"
WGX_BIN="/usr/local/bin/wgx"
WGX_OWNER="${SUDO_USER:-root}"

# Runtime state
IFACE=""
WG_PREFIX=""
IS_LXC=false
NETBIRD_ACTIVE=false
NETBIRD_INTERFACE=""

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# ============================================================================
# LOGGING & ERROR HANDLING
# ============================================================================
log()   { echo -e "${GREEN}[+]${NC} $*" | tee -a "$INSTALL_LOG"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$INSTALL_LOG" >&2; }
err()   { echo -e "${RED}[x]${NC} $*" | tee -a "$INSTALL_LOG" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $*"; }
die()   { err "$*"; exit 1; }

trap 'err "Installer failed at line $LINENO. See $INSTALL_LOG"' ERR

# ============================================================================
# UTILITIES
# ============================================================================
require_root() {
    [ "$EUID" -eq 0 ] || die "Run as root (sudo $0)"
}

have() { command -v "$1" >/dev/null 2>&1; }

append_if_missing() {
    local line=$1 file=$2
    grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

backup_file() {
    local f=$1
    [ -f "$f" ] && [ ! -f "${f}.wgx.bak" ] && cp -a "$f" "${f}.wgx.bak"
}

prompt_value() {
    local var=$1 prompt=$2 default=$3 value
    read -r -p "$prompt [$default]: " value
    value=${value:-$default}
    [ -n "$value" ] || die "Value cannot be empty."
    printf -v "$var" '%s' "$value"
}

prompt_port() {
    local var=$1 prompt=$2 default=$3 value
    while true; do
        read -r -p "$prompt [$default]: " value
        value=${value:-$default}
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
            printf -v "$var" '%s' "$value"; return
        fi
        warn "Enter a port 1-65535."
    done
}

prompt_int_range() {
    local var=$1 prompt=$2 default=$3 min=$4 max=$5 value
    while true; do
        read -r -p "$prompt [$default]: " value
        value=${value:-$default}
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
            printf -v "$var" '%s' "$value"; return
        fi
        warn "Enter a number between $min and $max."
    done
}

# ============================================================================
# ENVIRONMENT DETECTION
# ============================================================================
detect_lxc() {
    if [ -f /proc/1/environ ] && grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
        IS_LXC=true
        log "LXC container detected"
    elif grep -qa "container=" /proc/1/environ 2>/dev/null; then
        IS_LXC=true
        log "Container detected"
    fi
}

detect_outbound_iface() {
    IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -z "$IFACE" ] && IFACE=$(ip -4 route show default | awk '{print $5}' | head -1)
    [ -n "$IFACE" ] || die "Could not detect outbound interface"
    log "Outbound interface: $IFACE"
}

detect_netbird() {
    if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q netbird; then
        NETBIRD_ACTIVE=true
        if ip link show netbird >/dev/null 2>&1; then
            NETBIRD_INTERFACE="netbird"
        elif ip link show wt0 >/dev/null 2>&1; then
            NETBIRD_INTERFACE="wt0"
        fi
        [ -n "$NETBIRD_INTERFACE" ] && log "Netbird interface: $NETBIRD_INTERFACE"
    fi
}

# ============================================================================
# PROMPTS
# ============================================================================
gather_config() {
    echo
    info "=== Configuration (Enter = default) ==="
    prompt_port WG_PORT    "WireGuard UDP port"        "$WG_PORT"
    prompt_port XRAY_PORT  "Xray TCP port"             "$XRAY_PORT"
    prompt_value WG_SUBNET "WireGuard IPv4 subnet"     "$WG_SUBNET"
    prompt_value WG_NETWORK "WireGuard IPv4 network base" "$WG_NETWORK"
    prompt_int_range WG_MTU "WireGuard MTU"            "$WG_MTU" 576 1500
    prompt_value DB_DIR    "Database directory"        "$DB_DIR"
    prompt_value BACKUP_DIR "Backup directory"         "$BACKUP_DIR"
    prompt_value UNINSTALL_SCRIPT "Uninstall script path" "$UNINSTALL_SCRIPT"
    prompt_value WGX_OWNER "wgx owner"                 "$WGX_OWNER"

    id "$WGX_OWNER" >/dev/null 2>&1 || die "User does not exist: $WGX_OWNER"

    WG_PREFIX=${WG_SUBNET#*/}
    [ "$WG_PREFIX" != "$WG_SUBNET" ] || die "Subnet must include CIDR prefix (e.g. 10.76.0.0/24)"
    [[ "$WG_PREFIX" =~ ^[0-9]+$ ]] && (( WG_PREFIX >= 8 && WG_PREFIX <= 30 )) \
        || die "Invalid CIDR prefix: $WG_PREFIX"
}

# ============================================================================
# KERNEL / SYSCTL TUNING (STABILITY)
# ============================================================================
apply_sysctl_tuning() {
    log "Applying kernel/network tuning"

    cat > /etc/sysctl.d/99-wgx.conf <<EOF
# WireGuard + Xray stability tuning (managed by wgx installer)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 0

# Loose rp_filter — required for WireGuard in containers / multi-homed hosts
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${IFACE}.rp_filter = 2

# Forwarding / connection tracking
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_udp_timeout = 120
net.netfilter.nf_conntrack_udp_timeout_stream = 180

# UDP buffers — helps throughput / burst stability
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096

# TCP tuning for tunneled traffic
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Reduce TIME_WAIT pressure
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_syn_backlog = 8192
EOF

    # Apply tolerating missing modules (bbr may not be available)
    sysctl -p /etc/sysctl.d/99-wgx.conf >/dev/null 2>&1 || \
        sysctl --system >/dev/null 2>&1 || \
        warn "Some sysctl values could not be applied (kernel may not support all)"

    # Explicitly set the most critical ones (must succeed)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null
    sysctl -w "net.ipv4.conf.${IFACE}.rp_filter=2" >/dev/null

    log "Kernel tuning applied"
}

# ============================================================================
# FIREWALL (UFW + iptables) — persistent, reload-safe
# ============================================================================
install_iptables_persistent() {
    if ! dpkg -l iptables-persistent >/dev/null 2>&1; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent >/dev/null
    fi
}

configure_ufw() {
    log "Configuring UFW"

    # Forward policy ACCEPT
    sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

    backup_file /etc/ufw/before.rules

    # NAT table (idempotent): only add if not already present
    if ! grep -q "wgx NAT masquerade" /etc/ufw/before.rules 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        {
            echo "# wgx NAT masquerade"
            echo "*nat"
            echo ":POSTROUTING ACCEPT [0:0]"
            echo "-A POSTROUTING -s ${WG_SUBNET} -o ${IFACE} -j MASQUERADE"
            echo "COMMIT"
            echo ""
            cat /etc/ufw/before.rules
        } > "$tmp"
        install -m 640 -o root -g root "$tmp" /etc/ufw/before.rules
        rm -f "$tmp"
    fi

    # Forward ACCEPT rules (idempotent) — inserted before final COMMIT of *filter
    if ! grep -q "wgx forward" /etc/ufw/before.rules; then
        local tmp
        tmp=$(mktemp)
        awk '
            /^COMMIT$/ && !done {
                print "# wgx forward"
                print "-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
                print "-A ufw-before-forward -i wg0 -j ACCEPT"
                print "-A ufw-before-forward -o wg0 -j ACCEPT"
                done=1
            }
            { print }
        ' /etc/ufw/before.rules > "$tmp"
        install -m 640 -o root -g root "$tmp" /etc/ufw/before.rules
        rm -f "$tmp"
    fi

    # UFW rules (idempotent)
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow ssh              >/dev/null
    ufw allow "$WG_PORT"/udp   >/dev/null
    ufw allow "$XRAY_PORT"/tcp >/dev/null
    ufw allow in on wg0        >/dev/null
    ufw route allow in on wg0 out on "$IFACE" >/dev/null
    ufw route allow in on "$IFACE" out on wg0 >/dev/null

    ufw --force enable >/dev/null
    ufw reload >/dev/null

    log "UFW configured (SSH, WG:$WG_PORT/udp, Xray:$XRAY_PORT/tcp)"
}

# ============================================================================
# DEPENDENCIES
# ============================================================================
install_dependencies() {
    log "Installing dependencies"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        wireguard wireguard-tools \
        curl wget jq qrencode \
        iptables ufw fail2ban \
        unzip iproute2 ca-certificates \
        >/dev/null
    install_iptables_persistent
}

# ============================================================================
# WIREGUARD
# ============================================================================
setup_wireguard_keys() {
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    if [ ! -s /etc/wireguard/server_private.key ]; then
        umask 077
        wg genkey > /etc/wireguard/server_private.key
        log "Generated new server keypair"
    fi
    chmod 600 /etc/wireguard/server_private.key
    wg pubkey < /etc/wireguard/server_private.key > /etc/wireguard/server_public.key
    chmod 644 /etc/wireguard/server_public.key
}

build_wg_config() {
    local server_priv server_pub
    server_priv=$(cat /etc/wireguard/server_private.key)
    server_pub=$(cat /etc/wireguard/server_public.key)

    # Preserve existing peers on reinstall
    local existing_peers=""
    if [ -f /etc/wireguard/wg0.conf ]; then
        existing_peers=$(awk '/^\[Peer\]/{p=1} p' /etc/wireguard/wg0.conf || true)
    fi

    umask 077
    cat > /etc/wireguard/wg0.conf <<EOF
# Managed by wgx installer v${SCRIPT_VERSION}
# Manual changes will be preserved only for [Peer] blocks.
[Interface]
PrivateKey = ${server_priv}
Address = ${WG_NETWORK}.1/${WG_PREFIX}
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}
SaveConfig = false

# --- Stability: kernel + rp_filter + conntrack ---
PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = sysctl -w net.ipv4.conf.all.rp_filter=2
PostUp   = sysctl -w net.ipv4.conf.default.rp_filter=2
PostUp   = sysctl -w net.ipv4.conf.${IFACE}.rp_filter=2
PostUp   = sysctl -w net.ipv4.conf.wg0.rp_filter=0
PostUp   = iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp   = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${IFACE} -j MASQUERADE
PostUp   = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

PostDown = iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${IFACE} -j MASQUERADE
PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF

    # Netbird integration
    if [ "$NETBIRD_ACTIVE" = true ] && [ -n "$NETBIRD_INTERFACE" ]; then
        cat >> /etc/wireguard/wg0.conf <<EOF

# --- Netbird integration ---
PostUp   = iptables -A FORWARD -i wg0 -o ${NETBIRD_INTERFACE} -j ACCEPT
PostUp   = iptables -A FORWARD -i ${NETBIRD_INTERFACE} -o wg0 -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${NETBIRD_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -o ${NETBIRD_INTERFACE} -j ACCEPT
PostDown = iptables -D FORWARD -i ${NETBIRD_INTERFACE} -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${NETBIRD_INTERFACE} -j MASQUERADE
EOF
    fi

    # Re-append peers from users.db (source of truth)
    if [ -f "$DB_DIR/users.db" ] && [ -s "$DB_DIR/users.db" ]; then
        while IFS=',' read -r _user _uuid ip pub _rest; do
            [ -n "${pub:-}" ] || continue
            cat >> /etc/wireguard/wg0.conf <<EOF

[Peer]
# user: ${_user}
PublicKey = ${pub}
AllowedIPs = ${ip}/32
EOF
        done < "$DB_DIR/users.db"
    elif [ -n "$existing_peers" ]; then
        # Fallback: preserve peers if DB doesn't exist yet
        echo "" >> /etc/wireguard/wg0.conf
        echo "$existing_peers" >> /etc/wireguard/wg0.conf
    fi
}

start_wireguard() {
    log "Starting WireGuard"
    systemctl enable wg-quick@wg0 >/dev/null 2>&1
    systemctl restart wg-quick@wg0

    for i in {1..10}; do
        if systemctl is-active --quiet wg-quick@wg0; then
            log "WireGuard is up"
            return 0
        fi
        sleep 1
    done

    err "WireGuard failed to start"
    journalctl -u wg-quick@wg0 -n 30 --no-pager
    return 1
}

# ============================================================================
# XRAY
# ============================================================================
install_xray() {
    log "Installing Xray"

    if have xray || [ -x /usr/local/bin/xray ]; then
        log "Xray already installed, skipping download"
        return 0
    fi

    local ok=false
    if curl -fsSL --retry 3 --max-time 60 \
        https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh \
        -o /tmp/xray-install.sh; then
        chmod +x /tmp/xray-install.sh
        if bash /tmp/xray-install.sh install >/tmp/xray-install.log 2>&1; then
            ok=true
            log "Xray installed via official script"
        else
            warn "Official script failed; falling back to manual install"
        fi
    fi

    if [ "$ok" = false ]; then
        install_xray_manual
    fi

    [ -x /usr/local/bin/xray ] || die "Xray binary missing after install"
    /usr/local/bin/xray version >/dev/null || die "Xray binary not executable"
}

install_xray_manual() {
    local arch xarch version url
    arch=$(uname -m)
    case "$arch" in
        x86_64)  xarch="linux-64" ;;
        aarch64) xarch="linux-arm64-v8a" ;;
        armv7l)  xarch="linux-arm32-v7a" ;;
        *)       xarch="linux-64" ;;
    esac

    version=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -r '.tag_name // empty' 2>/dev/null)
    [ -n "$version" ] || version="v1.8.24"

    url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-${xarch}.zip"
    log "Downloading Xray $version ($xarch)"

    cd /tmp
    curl -fsSL --retry 3 -o xray.zip "$url" || die "Xray download failed"
    unzip -oq xray.zip

    install -m 755 xray /usr/local/bin/xray
    mkdir -p /usr/local/share/xray
    cp -f geoip.dat geosite.dat /usr/local/share/xray/ 2>/dev/null || true

    cat > /etc/systemd/system/xray.service <<'SVCEOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNPROC=10000
LimitNOFILE=1000000
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    cd - >/dev/null
}

setup_xray_keys() {
    if [ -s "$DB_DIR/xray_private.key" ] && [ -s "$DB_DIR/xray_public.key" ]; then
        log "Reusing existing Xray Reality keypair"
        return 0
    fi

    log "Generating Xray Reality keypair"
    local keys priv pub
    keys=$(/usr/local/bin/xray x25519)
    priv=$(echo "$keys" | grep -i private | awk '{print $NF}')
    pub=$(echo "$keys"  | grep -i public  | awk '{print $NF}')

    [ -n "$priv" ] && [ -n "$pub" ] || die "Failed to generate Xray keys"

    umask 077
    echo "$priv" > "$DB_DIR/xray_private.key"
    echo "$pub"  > "$DB_DIR/xray_public.key"
    chmod 600 "$DB_DIR/xray_private.key"
    chmod 644 "$DB_DIR/xray_public.key"
}

build_xray_config() {
    local priv short_id
    priv=$(cat "$DB_DIR/xray_private.key")

    # Short ID: reuse if file exists for stable client configs
    if [ -s "$DB_DIR/xray_shortid" ]; then
        short_id=$(cat "$DB_DIR/xray_shortid")
    else
        short_id=$(openssl rand -hex 8)
        echo "$short_id" > "$DB_DIR/xray_shortid"
        chmod 644 "$DB_DIR/xray_shortid"
    fi

    mkdir -p /usr/local/etc/xray /var/log/xray

    # Build clients array from DB (atomic write via temp)
    local clients="[]"
    if [ -f "$DB_DIR/users.db" ] && [ -s "$DB_DIR/users.db" ]; then
        clients=$(awk -F',' '{printf "{\"id\":\"%s\"},", $2}' "$DB_DIR/users.db" \
            | sed 's/,$//' \
            | awk '{print "["$0"]"}')
        [ "$clients" = "[]" ] && clients="[]"
    fi

    umask 077
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "dnsLog": false
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "vless-reality-grpc",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": ${clients},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.google.com:443",
          "xver": 0,
          "serverNames": ["www.google.com", "fonts.gstatic.com"],
          "privateKey": "${priv}",
          "shortIds": ["${short_id}"]
        },
        "grpcSettings": {
          "serviceName": "grpc",
          "idle_timeout": 60,
          "health_check_timeout": 20,
          "permit_without_stream": false
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpCongestion": "bbr",
          "mark": 0
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  },
  "policy": {
    "levels": {
      "0": { "handshake": 4, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5 }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false,
      "statsOutboundUplink": false,
      "statsOutboundDownlink": false
    }
  }
}
EOF

    chmod 640 /usr/local/etc/xray/config.json
    log "Xray config written"
}

setup_xray_permissions() {
    mkdir -p /var/log/xray
    local user=root
    if [ -f /usr/local/etc/xray/config.json ]; then
        : # placeholder for future
    fi
    # Detect service user from installed unit
    if [ -f /etc/systemd/system/xray.service ]; then
        user=$(grep -m1 '^User=' /etc/systemd/system/xray.service | cut -d= -f2 || echo root)
    elif [ -f /usr/lib/systemd/system/xray.service ]; then
        user=$(grep -m1 '^User=' /usr/lib/systemd/system/xray.service | cut -d= -f2 || echo root)
    fi
    user=${user:-root}

    if [ "$user" != "root" ] && ! id "$user" >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin "$user" 2>/dev/null || user=nobody
    fi

    chown -R "$user":"$(id -gn "$user" 2>/dev/null || echo nogroup)" /var/log/xray 2>/dev/null || true
    chmod 750 /var/log/xray
    touch /var/log/xray/access.log /var/log/xray/error.log
    chmod 640 /var/log/xray/*.log
}

start_xray() {
    log "Starting Xray"
    /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 \
        || warn "Xray config test reported issues"

    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray

    for i in {1..10}; do
        if systemctl is-active --quiet xray; then
            log "Xray is up"
            return 0
        fi
        sleep 1
    done

    err "Xray failed to start"
    journalctl -u xray -n 30 --no-pager
    return 1
}

# ============================================================================
# USERS DB
# ============================================================================
init_users_db() {
    mkdir -p "$DB_DIR" "$BACKUP_DIR"
    chmod 750 "$DB_DIR"
    chmod 755 "$BACKUP_DIR"
    touch "$DB_DIR/users.db"
    chmod 644 "$DB_DIR/users.db"
    normalize_users_db "$DB_DIR/users.db"
}

normalize_users_db() {
    local db_file=$1 tmp_file
    [ -f "$db_file" ] || return 0
    tmp_file=$(mktemp)
    awk -F',' 'BEGIN{OFS=","}
        NF>=6 {print $1,$2,$3,$6; next}
        NF==5 {print $1,$2,$3,$5; next}
        NF==4 {print; next}
        {print}' "$db_file" > "$tmp_file"
    install -m 644 "$tmp_file" "$db_file"
    rm -f "$tmp_file"
}

# ============================================================================
# CLI (wgx)
# ============================================================================
write_cli() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'DB=%q\n'                "$DB_DIR/users.db"
        printf 'WG_CONF=%q\n'           "/etc/wireguard/wg0.conf"
        printf 'XRAY_CONF=%q\n'         "/usr/local/etc/xray/config.json"
        printf 'XRAY_PUBLIC_KEY=%q\n'   "$DB_DIR/xray_public.key"
        printf 'XRAY_SHORTID=%q\n'      "$DB_DIR/xray_shortid"
        printf 'BACKUP_DIR=%q\n'        "$BACKUP_DIR"
        printf 'WG_PORT=%q\n'           "$WG_PORT"
        printf 'XRAY_PORT=%q\n'         "$XRAY_PORT"
        printf 'WG_BASE=%q\n'           "$WG_NETWORK"
        printf 'WG_PREFIX=%q\n'         "$WG_PREFIX"
        printf 'WG_MTU=%q\n'            "$WG_MTU"
    } > "$WGX_BIN"

    cat >> "$WGX_BIN" <<'CLIEOF'

WG_DNS="1.1.1.1, 8.8.8.8"
USE_SUDO=""; [ "$EUID" -ne 0 ] && USE_SUDO="sudo"
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; N='\033[0m'

log()   { echo -e "${G}[+]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*" >&2; }
err()   { echo -e "${R}[x]${N} $*" >&2; }

normalize_db() {
    [ -f "$DB" ] || return 0
    local t; t=$(mktemp)
    awk -F',' 'BEGIN{OFS=","}
        NF>=6 {print $1,$2,$3,$6; next}
        NF==5 {print $1,$2,$3,$5; next}
        NF==4 {print; next}
        {print}' "$DB" > "$t"
    $USE_SUDO install -m 644 "$t" "$DB"
    rm -f "$t"
}
normalize_db

get_next_ip() {
    local last
    if [ ! -s "$DB" ]; then echo "${WG_BASE}.2"; return; fi
    last=$(awk -F',' '{split($3,a,"."); print a[4]}' "$DB" | sort -n | tail -1)
    if [ -z "$last" ] || [ "$last" -lt 2 ]; then echo "${WG_BASE}.2"
    else echo "${WG_BASE}.$((last+1))"; fi
}

backup_configs() {
    local name="${1:-manual}" f
    f="$BACKUP_DIR/backup_${name}_$(date +%Y%m%d-%H%M%S).tar.gz"
    $USE_SUDO mkdir -p "$BACKUP_DIR"
    $USE_SUDO tar -czf "$f" "$WG_CONF" "$XRAY_CONF" "$DB" 2>/dev/null || true
    log "Backup: $f"
}

sync_xray() {
    $USE_SUDO touch "$DB"; $USE_SUDO chmod 644 "$DB"
    local clients t
    clients=$(awk -F',' 'NF>=4 {printf "{\"id\":\"%s\"},", $2}' "$DB" | sed 's/,$//')
    [ -z "$clients" ] && clients=""
    t=$(mktemp)
    $USE_SUDO jq ".inbounds[0].settings.clients = [ ${clients} ]" "$XRAY_CONF" > "$t"
    $USE_SUDO install -m 640 "$t" "$XRAY_CONF"
    rm -f "$t"
    if $USE_SUDO systemctl is-active --quiet xray; then
        $USE_SUDO systemctl reload xray 2>/dev/null || $USE_SUDO systemctl restart xray
    fi
    log "Xray synced"
}

gen_qr() {
    local user=$1 uuid=$2 server_ip pub shortid link
    server_ip=$(curl -4 -fsS --max-time 10 ifconfig.me || curl -fsS --max-time 10 ifconfig.me)
    pub=$(cat "$XRAY_PUBLIC_KEY" 2>/dev/null || echo "")
    shortid=$(cat "$XRAY_SHORTID" 2>/dev/null || echo "")

    link="vless://${uuid}@${server_ip}:${XRAY_PORT}?type=grpc&security=reality&serviceName=grpc&pbk=${pub}&sid=${shortid}&sni=www.google.com&fp=chrome&flow=&encryption=none#${user}"

    echo; echo -e "${G}===== XRAY LINK =====${N}"
    echo "$link"
    qrencode -t ansiutf8 -s 2 -m 1 "$link" 2>/dev/null || warn "QR failed"

    if [ -f "$BACKUP_DIR/wg-${user}.conf" ]; then
        echo; echo -e "${G}===== WG QR =====${N}"
        qrencode -t ansiutf8 -s 2 -m 1 < "$BACKUP_DIR/wg-${user}.conf" 2>/dev/null || warn "QR failed"
    fi
}

add_user() {
    local user=$1
    [ -n "$user" ] || { err "Usage: wgx add USERNAME"; return 1; }
    if grep -q "^${user}," "$DB" 2>/dev/null; then err "User exists"; return 1; fi

    local ip priv pub uuid server_ip server_pub
    ip=$(get_next_ip)
    priv=$($USE_SUDO wg genkey)
    pub=$(echo "$priv" | $USE_SUDO wg pubkey)
    uuid=$(cat /proc/sys/kernel/random/uuid)

    $USE_SUDO bash -c "echo '${user},${uuid},${ip},${pub}' >> '$DB'"

    # Append peer without restart (use wg set for hot reload)
    $USE_SUDO bash -c "cat >> '$WG_CONF' <<EOC

[Peer]
# user: ${user}
PublicKey = ${pub}
AllowedIPs = ${ip}/32
EOC"

    $USE_SUDO wg set wg0 peer "$pub" allowed-ips "${ip}/32" 2>/dev/null || \
        $USE_SUDO systemctl restart wg-quick@wg0

    server_ip=$(curl -4 -fsS --max-time 10 ifconfig.me)
    server_pub=$($USE_SUDO cat /etc/wireguard/server_public.key)

    $USE_SUDO mkdir -p "$BACKUP_DIR"
    $USE_SUDO tee "$BACKUP_DIR/wg-${user}.conf" >/dev/null <<EOC
[Interface]
PrivateKey = ${priv}
Address = ${ip}/${WG_PREFIX}
DNS = ${WG_DNS}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${server_ip}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOC
    $USE_SUDO chmod 600 "$BACKUP_DIR/wg-${user}.conf"

    sync_xray
    backup_configs "$user"

    echo; echo -e "${G}=== USER CREATED ===${N}"
    echo "User: $user"; echo "IPv4: $ip"; echo "UUID: $uuid"
    echo "WG cfg: $BACKUP_DIR/wg-${user}.conf"
    gen_qr "$user" "$uuid"
}

remove_user() {
    local user=$1
    [ -n "$user" ] || { err "Usage: wgx remove USERNAME"; return 1; }
    grep -q "^${user}," "$DB" || { err "User not found"; return 1; }

    local pub
    pub=$(awk -F',' -v u="$user" '$1==u{print $4}' "$DB")

    $USE_SUDO wg set wg0 peer "$pub" remove 2>/dev/null || true
    $USE_SUDO sed -i "/^${user},/d" "$DB"

    # Rebuild peers section from DB
    local tmp; tmp=$(mktemp)
    $USE_SUDO awk '/^\[Peer\]/{exit} {print}' "$WG_CONF" > "$tmp"
    while IFS=',' read -r u uuid ip p _rest; do
        [ -z "$u" ] && continue
        printf '\n[Peer]\n# user: %s\nPublicKey = %s\nAllowedIPs = %s/32\n' "$u" "$p" "$ip" >> "$tmp"
    done < "$DB"
    $USE_SUDO install -m 600 "$tmp" "$WG_CONF"
    rm -f "$tmp"

    sync_xray
    $USE_SUDO rm -f "$BACKUP_DIR/wg-${user}.conf"
    log "User removed: $user"
}

list_users() {
    [ -s "$DB" ] || { echo "No users"; return; }
    printf "%-15s %-36s %-16s %-10s\n" USERNAME UUID IPv4 STATUS
    echo "--------------------------------------------------------------------------"
    while IFS=',' read -r u uuid ip pub _rest; do
        local st="idle"
        if $USE_SUDO wg show wg0 latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p && $2>0 {found=1} END{exit !found}'; then
            st="active"
        fi
        printf "%-15s %-36s %-16s %-10s\n" "$u" "$uuid" "$ip" "$st"
    done < "$DB"
}

show_user() {
    local user=$1
    [ -n "$user" ] || { err "Usage: wgx show USERNAME"; return 1; }
    local line; line=$(grep "^${user}," "$DB" 2>/dev/null || true)
    [ -n "$line" ] || { err "User not found"; return 1; }
    IFS=',' read -r u uuid ip pub _rest <<< "$line"
    echo -e "${G}User:${N} $u"
    echo "UUID: $uuid"
    echo "IPv4: $ip"
    echo "PubKey: $pub"
    if [ -f "$BACKUP_DIR/wg-${u}.conf" ]; then
        echo; echo "--- WireGuard config ---"
        cat "$BACKUP_DIR/wg-${u}.conf"
        gen_qr "$u" "$uuid"
    fi
}

status_cmd() {
    echo "=== WireGuard ==="
    systemctl is-active wg-quick@wg0 >/dev/null && echo "service: active" || echo "service: inactive"
    $USE_SUDO wg show || true
    echo
    echo "=== Xray ==="
    systemctl is-active xray >/dev/null && echo "service: active" || echo "service: inactive"
    echo
    echo "=== Firewall ==="
    $USE_SUDO ufw status | head -20 || true
    echo
    echo "=== Forward rules ==="
    $USE_SUDO iptables -L ufw-before-forward -n --line-numbers 2>/dev/null | head -15 || true
}

case "${1:-}" in
    add)    add_user "${2:-}" ;;
    remove) remove_user "${2:-}" ;;
    list)   list_users ;;
    show)   show_user "${2:-}" ;;
    status) status_cmd ;;
    backup) backup_configs "${2:-}" ;;
    *)
        cat <<USAGE
wgx — WireGuard + Xray manager

Usage: wgx <command> [args]

Commands:
  add USERNAME      Create user (WireGuard + Xray), show QR codes
  remove USERNAME   Revoke user access
  list              List all users with live status
  show USERNAME     Show config + QR for user
  status            Service + firewall status
  backup [NAME]     Backup current configs
USAGE
        ;;
esac
CLIEOF

    chmod 755 "$WGX_BIN"
}

# ============================================================================
# SUDOERS
# ============================================================================
setup_sudoers() {
    if [ "$WGX_OWNER" != "root" ]; then
        echo "$WGX_OWNER ALL=(ALL) NOPASSWD: $WGX_BIN rm -f /" > /etc/sudoetcers.d/wgx
        chmod 440 /etc/s/sudoers.d/wgx
        visudo -cf /etc/sudoers.d/wgx >/dev/null || {udoers.d/wgx; warn "sudoers validation failed"; }
    fi
}

# ============================================================================
# UNINSTALLER
# ============================================================================
write_uninstaller() {
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'DB_DIR=%q\n' "$DB_DIR"
        printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
        printf 'IFACE=%q\n' "$IFACE"
        printf 'WG_SUBNET=%q\n' "$WG_SUBNET"
    } > "$UNINSTALL_SCRIPT"

    cat >> "$UNINSTALL_SCRIPT" <<'UNEOF'
read -r -p "Uninstall WireGuard + Xray? (y/N): " ans
[[ "${ans,,}" == "y" ]] || exit 0

BK="/tmp/wgx-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$BK" /etc/wireguard /usr/local/etc/xray "$DB_DIR" 2>/dev/null || true
echo "[+] Backup: $BK"

systemctl disable --now wg-quick@wg0 2>/dev/null || true
systemctl disable --now xray 2>/dev/null || true
ip link del wg0 2>/dev/null || true

rm -rf /etc/wireguard /usr/local/etc/xray /usr/local/share/xray
rm -rf /var/log/xray "$DB_DIR" "$BACKUP_DIR"
rm -f /usr/local/bin/wgx /usr/local/bin/xray /etc/sudoers.d/wgx
rm -f /etc/systemd/system/xray.service
rm -f /etc/sysctl.d/99-wgx.conf

iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -t nat -D POSTROUTING -s "$WG_SUBNET" -o "$IFACE" -j MASQUERADE 2>/dev/null || true
iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

[ -f /etc/ufw/before.rules.wgx.bak ] && mv /etc/ufw/before.rules.wgx.bak /etc/ufw/before.rules
ufw --force reload 2>/dev/null || true
systemctl daemon-reload

echo "[+] Uninstall complete"
UNEOF

    chmod 755 "$UNINSTALL_SCRIPT"
}

# ============================================================================
# PERSIST IPTABLES
# ============================================================================
persist_iptables() {
    netfilter-persistent save >/dev/null 2>&1 || true
}

# ============================================================================
# POST-INSTALL VERIFICATION
# ============================================================================
verify_install() {
    echo
    info "=== Verification ==="

    systemctl is-active --quiet wg-quick@wg0 && log "WireGuard: running" || warn "WireGuard: not running"
    systemctl is-active --quiet xray       && log "Xray: running"      || warn "Xray: not running"

    if iptables -L ufw-before-forward -n 2>/dev/null | grep -q wg0; then
        log "Firewall: wg0 forward rules present"
    else
        warn "Firewall: wg0 rules missing from ufw-before-forward"
    fi

    local ct; ct=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "n/a")
    log "conntrack_max: $ct"

    local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")
    log "TCP congestion control: $cc"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    : > "$INSTALL_LOG"
    chmod 640 "$INSTALL_LOG"

    echo "=================================================="
    echo "  WireGuard + Xray Installer v${SCRIPT_VERSION}"
    echo "  Stable-performance build (LXC/VPS)"
    echo "=================================================="

    require_root
    detect_lxc
    detect_outbound_iface
    detect_netbird
    gather_config

    install_dependencies
    apply_sysctl_tuning
    configure_ufw

    init_users_db
    setup_wireguard_keys
    build_wg_config
    start_wireguard

    install_xray
    setup_xray_keys
    build_xray_config
    setup_xray_permissions
    start_xray

    write_cli
    setup_sudoers
    write_uninstaller
    persist_iptables

    verify_install

    local server_ip
    server_ip=$(curl -4 -fsS --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")

    cat <<EOF

==================================================
              INSTALLATION COMPLETE
==================================================

Server IP    : ${server_ip}
WG endpoint  : ${server_ip}:${WG_PORT}/udp
Xray endpoint: ${server_ip}:${XRAY_PORT}/tcp
WG subnet    : ${WG_SUBNET}
WG MTU       : ${WG_MTU}

Commands:
  wgx add USERNAME      Create user (WG + Xray) with QR
  wgx list              List users with live status
  wgx show USERNAME     Show config + QR
  wgx remove USERNAME   Revoke access
  wgx status            Service + firewall status
  wgx backup [NAME]     Backup configs

Uninstall:
  sudo wgx-uninstall

Files:
  /etc/wireguard/wg0.conf
  /usr/local/etc/xray/config.json
  ${DB_DIR}/users.db
  ${BACKUP_DIR}/

Log: ${INSTALL_LOG}
==================================================
EOF
}

main "$@"