# WireGuard + Xray Installer

This repository provides a single installer script that sets up:

- WireGuard VPN server (`wg0`)
- Xray (`VLESS + gRPC + Reality`)
- UFW firewall rules
- Fail2ban
- A management CLI command: `wgx`

## What the installer configures

The script in `install.sh` performs these actions:

- Installs packages: `wireguard`, `curl`, `iptables`, `jq`, `qrencode`, `ufw`, `fail2ban`
- Creates data/backup directories:
 	- `/etc/wg-xray`
 	- `/root/wireguard/wg-xray-backups`
- Configures UFW:
 	- Allows SSH
 	- Opens WireGuard UDP port `51820`
 	- Opens Xray TCP port `10000`
- Enables IPv4 forwarding and applies kernel sysctl tuning
- Generates WireGuard server keys and `/etc/wireguard/wg0.conf`
- Installs and configures Xray at `/usr/local/etc/xray/config.json`
- Creates user database file: `/etc/wg-xray/users.db`
- Installs `wgx` CLI at `/usr/local/bin/wgx`

## Requirements

- Ubuntu/Debian-based server (uses `apt`)
- Root access
- Internet access during installation
- A fresh VPS is recommended

## Installation

Run as root:

```bash
chmod +x install.sh
sudo ./install.sh
```

If `sudo` is not available and you are already root:

```bash
./install.sh
```

## Usage

After installation, use the `wgx` command.

### Command summary

```bash
wgx add USERNAME
wgx remove USERNAME
wgx list
wgx show USERNAME
wgx backup [NAME]
```

### Usage examples

Add a new user:

```bash
wgx add alice
```

List all users:

```bash
wgx list
```

Show one user details and QR output:

```bash
wgx show alice
```

Remove a user:

```bash
wgx remove alice
```

Create manual backup:

```bash
wgx backup manual
```

## Important file locations

- WireGuard config: `/etc/wireguard/wg0.conf`
- Xray config: `/usr/local/etc/xray/config.json`
- Users database: `/etc/wg-xray/users.db`
- Xray public key: `/etc/wg-xray/xray_public.key`
- Backups: `/root/wireguard/wg-xray-backups`

## Notes

- Default WireGuard subnet is `100.76.0.0/24`.
- Client WireGuard configs are saved in the backup directory as `wg-<username>.conf`.
- Xray links are saved as `<username>-xray-link.txt` in the backup directory.
- `wgx show <username>` attempts to print both XRAY and WireGuard QR codes.

## Security recommendations

- Change SSH port and harden SSH auth before exposing the server.
- Keep the server updated (`apt update && apt upgrade`).
- Periodically rotate keys and review firewall rules.
- Backup `/etc/wg-xray`, `/etc/wireguard`, and `/usr/local/etc/xray` regularly.
