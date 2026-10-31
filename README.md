# Xray-Fusion

Deploy a VLESS + REALITY server with Vision, then manage it with `xrf`.

[![Tests](https://github.com/zjlgdx/xray/actions/workflows/test.yml/badge.svg)](https://github.com/zjlgdx/xray/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Before you start

Run the commands below **on your Linux VPS**, using an account with `sudo` access
(or omit `sudo` if logged in as root).

- **Server:** Ubuntu/Debian or CentOS/RHEL, with systemd and x86-64 or ARM64.
- **Tools:** `curl` and `git` must be available before running the installer.
- **Network:** allow inbound **TCP 443** in your VPS firewall and provider's
  security rules. Make sure another service is not already using that port.
  The installer does not change firewall rules.
- **REALITY target:** choose a reachable HTTPS hostname for camouflage. You do
  not need to own the domain or obtain a certificate. There is no default target;
  see [target selection and diagnostics](docs/advanced.md#fresh-installation).

## Install and connect

### 1. Install the server

Replace `your-verified-target.example` with your chosen REALITY hostname. This is
an example placeholder, not a working target.

```bash
export XRAY_SNI=your-verified-target.example
curl -fsSL https://raw.githubusercontent.com/zjlgdx/xray/main/install.sh |
  sudo -E bash -s -- --yes
```

The installer creates a new server configuration on port 443. It selects the
newest published Xray release, **including prereleases**. To choose a specific
release, append `--version vX.Y.Z`, replacing the placeholder with a release tag.

Already installed? Use [Update](#update) below; a fresh install will not overwrite
an existing installation.

### 2. Check the server

```bash
sudo xrf health
```

Resolve any reported failures before connecting. See [Troubleshooting](TROUBLESHOOTING.md)
if installation or health checks fail.

### 3. Connect your client

```bash
sudo xrf links
```

Copy the generated `vless://` link into a client that supports **VLESS + REALITY +
Vision**, then enable the connection and open a website. Keep the link private:
it contains your connection credentials.

A passing server health check does not prove that your client can connect. Test
from the device and network you intend to use.

## Everyday commands

| Task | Command |
| --- | --- |
| Show installed version | `sudo xrf status` |
| Show client connection link | `sudo xrf links` |
| Check server health | `sudo xrf health` |
| Validate configuration | `sudo xrf check --deep` |
| Follow logs | `sudo xrf logs --follow` |
| Create a configuration backup | `sudo xrf backup create` |

For restore instructions and other options, see [backup and restore](docs/advanced.md#backup-and-restore).
Backups contain credentials; keep them private too.

## Update

### Xray core

```bash
sudo xrf upgrade --version latest
sudo xrf health
```

This preserves configuration and credentials, but **restarts Xray and interrupts
active connections**. `latest` includes prereleases; use `--version vX.Y.Z` to
select a specific release. Reconnect and test your actual client afterward.

### Xray-Fusion tools

```bash
curl -fsSL https://raw.githubusercontent.com/zjlgdx/xray/main/install.sh |
  sudo bash -s -- --update-tool
```

This updates the management scripts without changing the Xray core, configuration,
service or credentials. It does not require `XRAY_SNI`. The updater prints a
backup path and restores the previous tools if the update or status check fails.
Keep the backup until you have confirmed the updated tools work.

## Uninstall

```bash
sudo xrf uninstall
```

This stops Xray and removes its core, configuration and service. Management tools,
state and historical backups remain; see [removal details](TROUBLESHOOTING.md#online-wrapper-or-uninstall-fails).

## More help

- [Troubleshooting](TROUBLESHOOTING.md) — installation and connection problems.
- [Advanced configuration](docs/advanced.md) — targets, versions, backups and paths.
- [Contributing](CONTRIBUTING.md) — development setup and tests.

## License

[MIT](LICENSE)
