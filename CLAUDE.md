# xray-fusion

Bash tool for a fresh VLESS + REALITY server with the Vision flow and a single raw-transport inbound. It does not manage Caddy, certificates, plugins, templates, firewall rules, sysctl tuning or a second TLS inbound.

## Quick reference

~~~bash
make fmt
make lint
make test-unit
make test-integration

xrf test-sni your-target.example --target your-target.example:443
sudo XRAY_SNI=your-target.example xrf install --yes
sudo xrf links
sudo xrf status
sudo xrf upgrade --version latest
sudo xrf backup create --name before-change
sudo xrf logs --lines 100
sudo xrf uninstall
~~~

`XRAY_SNI` is required for fresh install; there is no universal default target. The target probe is advisory. `XRAY_REALITY_DEST` defaults to `<XRAY_SNI>:443`. Install validates local inputs and candidate Xray config, and refuses existing managed artifacts. Upgrade is the binary-only path for a managed installation.

`latest` selects the newest published non-draft official Xray-core release, including prereleases. v26.9.9 was the newest verified during this change, not a permanent default. Unknown or legacy configuration formats are not an automatic migration path.

## Structure

| Path | Purpose |
| --- | --- |
| `bin/xrf`, `commands/` | CLI and user workflows |
| `lib/`, `modules/` | Core, state, validation, backup, and I/O helpers |
| `services/xray/` | Xray install, config rendering, upgrade, systemd unit, links |
| `scripts/e2e/` | Fresh Docker lifecycle smoke |
| `tests/unit/`, `tests/integration/` | Bats suites |

## Coding rules

Use Bash strict mode, 2-space indentation, source guards for libraries, explicit module dependencies, and structured `core::log` output in runtime/library paths. Do not add EXIT traps inside utility functions. Prefer `io::atomic_write` for managed files and `core::with_flock` around shared state changes. Use the repository's ShellCheck and shfmt settings; test the production path for behavior changes.

State stores full client credentials, with directory mode 0700 and state file mode 0600. `sudo xrf links` prints the client URI. Xray access/error output goes to stdout/stderr and systemd journald. Backups are private and restore only a validated current managed release layout; retain reported recovery material if rollback fails.

Local Bats and Docker lifecycle tests do not prove real systemd activation or client interoperability. The Docker smoke uses the official binary and a systemctl mock. Validate the actual client through the VPS separately when needed.

See [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md), [tests/README.md](tests/README.md), and [architecture decisions](docs/adr/). Earlier ADRs may document removed product lines as history.
