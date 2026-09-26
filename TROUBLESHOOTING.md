# Troubleshooting

Use these steps for the current managed VLESS + REALITY installation. Fresh install requires an explicit SNI; `xrf upgrade` changes the binary while preserving an existing managed configuration. Old dual-topology, Caddy, certificate, plugin, template and standalone export commands are no longer supported.

## Installation refuses to continue

Run `xrf install --help` and remove retired flags such as `--topology`, `--domain`, `--plugins`, `--template`, and VLESS encryption options. Supply an explicit target SNI:

~~~bash
xrf test-sni your-target.example --target your-target.example:443
sudo XRAY_SNI=your-target.example xrf install --dry-run
sudo XRAY_SNI=your-target.example xrf install --yes
~~~

The probe checks the same target host, port and SNI that you intend to configure for TLS 1.3, HTTP/2 and redirects. It is diagnostic, not an installation gate. Use `XRAY_REALITY_DEST=host:port` if the destination differs from `<XRAY_SNI>:443`. The target should be chosen and checked for your environment; the installer has no universal default.

If installation reports existing managed artifacts, use `sudo xrf upgrade --version latest` for a binary update. Do not rerun fresh install over a live configuration. If an earlier install failed, inspect the reported paths and service state before cleanup.

## Version resolution or download fails

The default `latest` means the newest published, non-draft official Xray-core release by publication time, including prereleases. During this change, the verified newest release was v26.9.9. The tool does not fall back to an older stable version when the release API is unavailable or the newest metadata is invalid.

Check network access to the official GitHub release API and assets, then retry. For an intentionally pinned release use `--version vX.Y.Z`. Install, upgrade and smoke validation share the version policy. Neither path supports migration of retired configuration layouts.

## Xray does not start

~~~bash
sudo xrf status
sudo xrf check --deep
sudo /usr/local/bin/xray -test -confdir /usr/local/etc/xray/active -format json
sudo journalctl -u xray.service -n 100 --no-pager
~~~

For custom `XRF_PREFIX` or `XRF_ETC`, substitute the paths shown by `xrf status` or the rendered systemd unit. Check port 443 ownership with `sudo ss -ltnp`, and verify your own firewall and VPS security-group rules. The installer does not change global firewall or sysctl settings.

Xray access and error output goes to stdout/stderr and into journald. Use `sudo xrf logs --follow` to watch it. Journald handles retention and rotation; there is no managed log file or logrotate service.

## Client link is unavailable

Connection state contains the private key material needed to render links. The state directory is mode 0700 and state file mode 0600. Run `sudo xrf links` or use equivalent authorized root access; a nonprivileged user should receive a clear error instead of a placeholder URI. Do not loosen state permissions or publish the URI in logs.

The URI represents one REALITY inbound with `xtls-rprx-vision` flow. It must be used with a compatible, current Xray client. A passing server configuration test does not prove a client can connect through the VPS; test the actual client path and expected target sites after an upgrade.

## Target-site diagnosis

~~~bash
xrf test-sni your-target.example --target your-target.example:443
xrf test-sni your-target.example --json
~~~

A failed TLS 1.3, HTTP/2, or no-redirect check means the chosen target is unsuitable for the configured pair. The diagnostic checks the external site directly and does not prove inbound reachability to the VPS. Match client SNI to the configured `XRAY_SNI`.

## Backup or restore fails

~~~bash
sudo xrf backup list
sudo xrf backup verify <name>
sudo xrf backup restore <name>
~~~

Encrypted backups also need `--password-file <path>` or a password. Create requires the current managed state, configuration digest and active release. Restore checks archive integrity and tests the archived release before stopping Xray. It then creates a pre-restore backup and attempts a bounded rollback if replacement or restart fails. If rollback itself fails, follow the reported private recovery path and preserve those files for manual repair.

An archive from an unknown or retired layout is not a supported migration source. Backups include complete credentials; store them privately.

## Online wrapper or uninstall fails

The online installer uses one verified `git clone` path and requires Git plus an explicit `XRAY_SNI`. A clone or integrity failure stops installation rather than trying a tarball or alternate download. Use only the current `zjlgdx/xray` source.

~~~bash
sudo xrf uninstall
~~~

The online uninstaller delegates to the installed `xrf` command and only removes its own global link. It does not have a `--keep-config` option or an unverified manual fallback. An uninstall error should be investigated before removing artifacts manually. Historical backups and state may remain, while the managed binary, configuration and service are removed.

For further details, see [advanced configuration](docs/advanced.md) and [error codes](docs/ERROR_CODES.md).
