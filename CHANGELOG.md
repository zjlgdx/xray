# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Fresh installation renders one VLESS + REALITY inbound with raw transport and the Vision flow. An explicit `XRAY_SNI` is required; no target site is built in.
- `latest` resolves the newest published non-draft official Xray-core release, including prereleases. The newest verified for this change was v26.9.9; the product does not pin that tag.
- Existing managed installations use binary-only `xrf upgrade`; fresh install refuses existing artifacts. Legacy or unknown layouts are not automatically migrated.
- Xray access/error output is collected by systemd journald. Client links are VLESS URIs read from private state (directory 0700, state file 0600).
- Backup creation and restore require the current managed REALITY layout, private state, and configuration digest. Restore validates the archived release before stopping Xray and retains bounded recovery material when rollback cannot finish.
- The online installer uses one Git clone path with commit and applicable tag-signature checks; the default repository is zjlgdx/xray.

### Removed
- Dual-topology/TLS inbound, Caddy and certificate synchronization, plugin/template/standalone export commands, automatic firewall and sysctl changes, file-log/logrotate branch, and unsupported online `--keep-config`.

### Verification
- Local unit suite: 977 passed, 16 skipped; integration suite: 28 passed, 1 skipped.
- Fresh Ubuntu Docker lifecycle: five scenarios passed with official Xray v26.9.9; systemctl was mocked while the Xray service user ran the real configuration test.
- These checks do not prove a real systemd service or client-to-VPS connection. GitHub Actions had not run for this change at the time of this entry.

---

## [1.0.0] - 2025-11-09

### Added
- **Automated testing framework** based on bats-core
  - 96 unit tests with ~80% code coverage
  - 5 test files covering core modules
- **CI/CD pipeline** (GitHub Actions)
  - Lint workflow (ShellCheck)
  - Format workflow (shfmt)
  - Test workflow (bats)
  - Security workflow
- **Independent certificate sync script** (scripts/caddy-cert-sync.sh)
  - Extracted from caddy.sh HERE-doc (195 lines → standalone script)
  - Supports both repo and standalone execution
- **Architecture Decision Records** (ADR-009)

### Changed
- **Certificate sync mechanism** - From systemd Path to Timer unit (ADR-002)
  - More reliable than inotify-based Path units
  - 10-minute check interval (sufficient for 60-90 day cert lifetimes)
- **Xray certificate reload** - Uses restart instead of reload (ADR-003)
  - Xray-core does not support SIGHUP graceful reload
  - Confirmed by official GitHub discussions
- **Certificate validation** - Supports both RSA and ECDSA (ADR-004)
  - Uses public key hash comparison (algorithm-agnostic)
- **Module organization** - Extracted cert-sync from monolithic script (ADR-008)
  - Reduced caddy.sh from 444 lines to 259 lines (-41.7%)

### Removed
- **OCSP stapling support** - Let's Encrypt sunset on 2025-01-30 (ADR-005)
- **Config test skip option** - XRF_SKIP_XRAY_TEST environment variable (ADR-007)
  - Configuration validation is critical and cannot be bypassed

### Fixed
- **Certificate sync concurrency** - Added flock-based protection (ADR-006)
- **Atomic file operations** - Consistent across all modules
- **Trap handling** - Removed traps from utility functions to avoid interference

### Security
- **Systemd service hardening**
  - ProtectSystem=strict
  - NoNewPrivileges=true
  - PrivateTmp=true
- **Plugin system** - Path traversal protection
- **Atomic lock file creation** - Prevents TOCTOU (CWE-362) and ownership issues (CWE-283)

---

## [0.9.0] - 2025-09-XX

### Added
- **Unified parameter system** (ADR-001)
  - Consistent --arg syntax across install.sh and xrf
  - Pipe-friendly: `curl | bash -s -- --domain x.com`
- **Plugin system architecture**
  - Hook-based extension system
  - Enable/disable plugins via CLI
- **Four built-in plugins**
  - cert-auto: Caddy-based automatic certificate management
  - firewall: UFW firewall configuration
  - logrotate-obs: Log rotation for OBS scenarios
  - links-qr: QR code generation for client links
- **Dual topology support**
  - reality-only: VLESS+Reality on port 443
  - vision-reality: VLESS+Vision (8443) + Reality (443)

### Changed
- **Parameter passing** - Migrated from environment variables to command-line arguments
- **Installation method** - Fully pipe-friendly with proper argument forwarding

### Security
- **RFC-compliant domain validation** - Rejects private networks (RFC 1918)
- **Input validation** - All entry points validate user input

---

## [0.1.0] - 2025-08-XX (Initial Release)

### Added
- Basic Xray installation and configuration
- Reality protocol support
- Systemd integration
- Basic logging framework
- Core utility functions (lib/core.sh)

[Unreleased]: https://github.com/zjlgdx/xray/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/zjlgdx/xray/releases/tag/v1.0.0
[0.9.0]: https://github.com/zjlgdx/xray/compare/v0.1.0...v0.9.0
[0.1.0]: https://github.com/zjlgdx/xray/releases/tag/v0.1.0
