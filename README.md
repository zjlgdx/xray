# Xray-Fusion

One-command VLESS + REALITY + Vision deployment with private client credentials.

[![Tests](https://github.com/zjlgdx/xray/actions/workflows/test.yml/badge.svg)](https://github.com/zjlgdx/xray/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Quick Start

Choose a REALITY target that you have verified, for example with
`./bin/xrf test-sni <sni> --target <host:port>` from a source checkout. Set its SNI
explicitly; `XRAY_REALITY_DEST` defaults to `<XRAY_SNI>:443`. The diagnostic checks
the actual target host and port with that SNI for TLS 1.3, HTTP/2, and redirects.
It is advisory: installation validates local inputs and Xray configuration, not
live reachability of an external site.

```bash
export XRAY_SNI=your-verified-target.example
curl -fsSL https://raw.githubusercontent.com/zjlgdx/xray/main/install.sh | sudo -E bash -s -- --yes
sudo xrf links
sudo xrf status
```

A fresh install uses the newest published non-draft Xray release, including
prereleases. The newest verified for this change was v26.9.9; the default is
not pinned to that tag. Existing installations use
`sudo xrf upgrade --version latest`. Legacy or unknown configuration layouts
are not automatically migrated.

The installed tool contains runtime scripts, the systemd unit, the standalone
uninstaller, and the license. Development tests and documentation remain in the
repository. Installer help is available without creating temporary files.

## Commands

| Command | Description |
|---------|-------------|
| `xrf status` | Installed Xray version and active configuration path |
| `xrf links` | Connection links |
| `xrf logs` | View logs |
| `xrf health` | Health check |
| `xrf upgrade --version vX.Y.Z` | Upgrade the core while preserving configuration |
| `xrf backup` | Create, verify, list, and restore current managed-layout backups |
| `xrf test-sni` | Diagnose an explicit REALITY target |
| `xrf uninstall` | Remove installation |

## Uninstall

```bash
sudo xrf uninstall
```

## Requirements

- Linux (Ubuntu/Debian/CentOS)
- systemd
- 64-bit architecture
- Git for the online installer

## Documentation

| Document | Description |
|----------|-------------|
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Common issues and solutions |
| [docs/advanced.md](docs/advanced.md) | Advanced configuration |
| [docs/development-environments.md](docs/development-environments.md) | Host shell and optional thin-devbox-shell workflow |
| [docs/agent-session-template.md](docs/agent-session-template.md) | Portable Codex / agent startup template |
| [docs/adr/](docs/adr/) | Architecture decisions |

## License

MIT

## Upgrading an existing server

Use `sudo xrf upgrade --version vX.Y.Z` for an explicit release. `--version latest`
selects the newest published, non-draft GitHub release by publication time,
including prereleases. The same rule applies to a fresh install and the lifecycle
smoke test when no version is specified. There is no automatic upgrade.

The command holds the configuration lock, backs up the binary, active configuration
and state under `/var/lib/xray-fusion/upgrades/`, downloads and verifies the candidate,
and validates the existing configuration before replacing the executable atomically.
It restarts Xray (disconnecting existing connections), verifies the running executable
hash, then updates the recorded version. Restart, process verification or metadata
commit failure restores the previous binary and metadata and restarts the old core.
Backups contain credentials and are stored in directories accessible only to their owner.
An interrupted machine or rollback failure may still require manual recovery from the
reported backup; backups are retained until the operator removes them.

`xrf install` refuses existing managed artifacts. It is a fresh-install command,
not a way to upgrade or regenerate a live server's credentials. For configuration-only
changes, the renderer validates before switching the active directory and restores the
previous active directory if restart fails. A core change is not skipped merely because
the configuration hash is unchanged.

Process/configuration checks do **not** prove REALITY client compatibility. After an
upgrade, test the actual client through the VPS, including the expected target sites.
Do not substitute a request through a different proxy or a direct VPS curl for that test.

### Logging during configuration changes

Xray access and error output goes to stdout/stderr and is collected by systemd's
journal. Use `sudo xrf logs` or `journalctl -u xray.service`. Journald owns
retention and rotation; this tool does not create file logs or logrotate jobs.
Configure `XRAY_LOG_LEVEL` for a bounded diagnostic session, then return it to
the normal level.
