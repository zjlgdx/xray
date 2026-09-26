# Xray-Fusion

One-command Xray proxy deployment with automatic certificate management.

[![Tests](https://github.com/xrf9268-hue/xray/actions/workflows/test.yml/badge.svg)](https://github.com/xrf9268-hue/xray/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Quick Start

```bash
# Install (no domain required)
curl -sL https://raw.githubusercontent.com/xrf9268-hue/xray/main/install.sh | bash -s -- --topology reality-only

# View connection links
xrf links

# Check status
xrf status
```

That's it! Copy the link to your client app and connect.

## With Your Own Domain

If you have a domain with DNS pointing to your server:

```bash
curl -sL https://raw.githubusercontent.com/xrf9268-hue/xray/main/install.sh | bash -s -- \
  --topology vision-reality \
  --domain your.domain.com \
  --plugins cert-auto
```

## Commands

| Command | Description |
|---------|-------------|
| `xrf status` | Service status |
| `xrf links` | Connection links |
| `xrf logs` | View logs |
| `xrf health` | Health check |
| `xrf upgrade --version vX.Y.Z` | Upgrade the core while preserving configuration |
| `xrf export` | Export configs (`uri/v2rayn/clash/sub/qr/all`) |
| `xrf uninstall` | Remove installation |

## Uninstall

```bash
xrf uninstall
```

## Requirements

- Linux (Ubuntu/Debian/CentOS)
- systemd
- 64-bit architecture

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

`xrf install` refuses an existing active configuration. It is a fresh-install command,
not a way to upgrade or regenerate a live server's credentials. For configuration-only
changes, the renderer validates before switching the active directory and restores the
previous active directory if restart fails. A core change is not skipped merely because
the configuration hash is unchanged.

Process/configuration checks do **not** prove REALITY client compatibility. After an
upgrade, test the actual client through the VPS, including the expected target sites.
Do not substitute a request through a different proxy or a direct VPS curl for that test.

### Logging during configuration changes

Configuration rendering preserves the existing `00_log.json` log object. Explicit
`XRAY_LOG_LEVEL`, `XRAY_ACCESS_LOG`, and `XRAY_ERROR_LOG` environment variables override
only their corresponding fields; an empty log path explicitly selects stdout.
Fresh installs retain the previous warning-only default with access logging disabled.

For file logging, provision a writable directory for the `xray` system user (for example,
a systemd drop-in with `LogsDirectory=xray`, compatible with `ProtectSystem=strict`),
restrict log permissions, and configure logrotate separately. Changing a path alone
does not create its directory or bypass the service sandbox. Debug logging is for a
bounded diagnostic session; lower it to info after reproducing the fault. A logrotate
size threshold is checked on invocation, not continuously; choose an appropriate timer.
