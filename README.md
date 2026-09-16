# WireGuard + Xray Installer

This repository provides an automated installer for a high-performance WireGuard + Xray server on Ubuntu/Debian-based VPS or LXC hosts.

It configures:

- WireGuard interface `wg0`
- Xray with `VLESS + gRPC + Reality`
- UFW firewall rules
- fail2ban
- optional NetBird interface integration
- `wgx` CLI for user management
- automatic backups and an uninstall helper

## What the installer configures

The installer script (`install.sh`) performs the following actions:

- Installs packages such as `wireguard`, `curl`, `iptables`, `jq`, `qrencode`, `ufw`, `fail2ban`, and supporting networking utilities
- Creates directories such as `/etc/wg-xray` and `/root/wireguard/wg-xray-backups`
- Configures UFW to allow SSH, WireGuard, and Xray traffic
- Enables IPv4 forwarding and applies kernel tuning
- Generates WireGuard server keys and `/etc/wireguard/wg0.conf`
- Installs and configures Xray at `/usr/local/etc/xray/config.json`
- Creates the user database at `/etc/wg-xray/users.db`
- Installs the `wgx` CLI at `/usr/local/bin/wgx`
- Writes an uninstall helper at `/usr/local/bin/wgx-uninstall`

## Requirements

- Ubuntu/Debian-based server
- Root access
- Internet connectivity during installation
- A fresh VPS is recommended
- A valid outbound network interface for the server

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

The installer will prompt for several settings, including:

- WireGuard UDP port
- Xray TCP port
- WireGuard subnet and network base
- MTU
- database directory
- backup directory
- uninstall script path
- owner for the `wgx` command

## Default configuration

Unless overridden during setup, the script uses these defaults:

- WireGuard port: `21821/udp`
- Xray port: `10000/tcp`
- WireGuard subnet: `10.76.0.0/24`
- MTU: `1420`
- Database directory: `/etc/wg-xray`
- Backup directory: `/root/wireguard/wg-xray-backups`

## Usage

After installation, use the `wgx` command:

```bash
wgx add USERNAME
wgx remove USERNAME
wgx list
wgx show USERNAME
wgx status
wgx backup [NAME]
```

### Examples

Add a new user:

```bash
wgx add alice
```

List all users:

```bash
wgx list
```

Show one user with configuration and QR output:

```bash
wgx show alice
```

Remove a user:

```bash
wgx remove alice
```

Check service and firewall status:

```bash
wgx status
```

Create a manual backup:

```bash
wgx backup alice
```

## Important file locations

- WireGuard config: `/etc/wireguard/wg0.conf`
- Xray config: `/usr/local/etc/xray/config.json`
- Users database: `/etc/wg-xray/users.db`
- Xray public key: `/etc/wg-xray/xray_public.key`
- Xray short ID: `/etc/wg-xray/xray_shortid`
- Backups: `/root/wireguard/wg-xray-backups`
- Install log: `/var/log/wgx-install.log`
- Uninstall helper: `/usr/local/bin/wgx-uninstall`

## Notes

- The default WireGuard subnet is `10.76.0.0/24`.
- The configuration is IPv4-focused by default.
- Client WireGuard configs are stored in the backup directory as `wg-<username>.conf`.
- `wgx show <username>` attempts to print both XRAY and WireGuard QR output.
- Existing peer entries are preserved when possible during reinstall operations.

## Security recommendations

- Change SSH port and harden SSH authentication before exposing the server to the internet.
- Keep the server updated with `apt update && apt upgrade`.
- Review firewall rules and exposed ports regularly.
- Periodically rotate keys and back up `/etc/wg-xray`, `/etc/wireguard`, and `/usr/local/etc/xray`.
- Restrict access to sensitive configuration and backup directories.

## Uninstall

```bash
sudo wgx-uninstall
```

This removes the installed WireGuard and Xray components and creates a backup archive before removal.

## Troubleshooting

Check the install log if the setup fails:

```bash
cat /var/log/wgx-install.log
```

Verify service health:

```bash
systemctl status wg-quick@wg0
systemctl status xray
wgx status
```

If needed, inspect the generated config files and ensure the server has the required outbound interface and firewall access.
