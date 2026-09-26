# Advanced Configuration

Xray-Fusion installs one VLESS + REALITY inbound using the Vision flow (`xtls-rprx-vision`) over raw transport. It does not install a separate TLS inbound, Caddy, certificates, plugins, templates, firewall rules, or host TCP tuning.

## Fresh installation

Choose an actual target whose TLS endpoint accepts your SNI, supports TLS 1.3 and HTTP/2, and does not redirect. The SNI is required; there is no built-in target recommendation. The network probe is advisory, while input and candidate Xray configuration validation are required for installation.

~~~bash
./bin/xrf test-sni your-target.example --target your-target.example:443
sudo XRAY_SNI=your-target.example xrf install --yes
sudo xrf links
~~~

For a different destination, set `XRAY_REALITY_DEST=host:port` along with `XRAY_SNI`. Without it, the destination is `<XRAY_SNI>:443`. A hostname in the destination may differ from the SNI; test the exact pair with `xrf test-sni <sni> --target <host:port>`. The configured Xray inbound listens on port 443 by default. IPv4-only hosts use an IPv4 listen address and DNS strategy; IPv6-capable hosts use dual-stack settings.

Supported install options include `--version latest|vX.Y.Z`, `--uuid`, `--uuid-from-string`, `--fingerprint`, `--yes`, `--dry-run`, and `--debug`. See `xrf install --help` for the current parser. Existing installations must use `xrf upgrade` for binary updates; `install` rejects existing managed artifacts rather than regenerating credentials.

## Xray version

The default `latest` resolves the newest published, non-draft release by publication time from the official Xray-core releases API, including prereleases. The latest release verified during this change was v26.9.9; it is not a version pinned into the product. API failure or invalid newest release metadata fails closed rather than selecting an older stable release. The same resolver serves install, upgrade, and the lifecycle smoke test.

~~~bash
sudo xrf upgrade --version latest
sudo xrf upgrade --version v26.9.9
~~~

Upgrade replaces the Xray binary while retaining the managed configuration and client credentials. It validates the candidate and the existing configuration, restarts the service, checks the running executable, and restores the prior binary and metadata on a bounded failure path. A restart interrupts existing connections. This is not a legacy topology migration interface.

## Private credentials and links

The managed state directory is mode 0700 and the state file is mode 0600. It contains the full connection credentials. Use `sudo xrf links` (or equivalent authorized root access) to print the VLESS URI. Share that URI only with the intended client; the normal CLI does not export alternate client formats or generate QR files.

The server config contains a REALITY shortId pool. A client URI uses its selected shortId; the pool is not a per-client secret generator. The URI includes the Vision flow, SNI, public key, shortId, fingerprint and configured server address.

## Backup and restore

~~~bash
sudo xrf backup create --name before-change
sudo xrf backup create --name encrypted-copy --encrypt --password-file /root/backup.pass
sudo xrf backup list
sudo xrf backup verify <name>
sudo xrf backup restore <name> --password-file /root/backup.pass
sudo xrf backup delete <name>
~~~

The password option is needed only for encrypted archives. Backups include private state and the matching configuration digest, so keep archives and passwords private. Create and restore work only with the current managed REALITY release layout; unknown or legacy layouts are rejected before service replacement. Restore validates the archived release with Xray before stopping the service, creates a pre-restore backup, and keeps bounded recovery material when rollback cannot finish. Check the reported path if manual recovery is required.

## Logs and diagnostics

Xray writes access and error output to stdout/stderr; systemd collects it in journald. Journald controls retention and rotation. The tool does not create file logs or logrotate jobs.

~~~bash
sudo xrf logs --lines 100
sudo xrf logs --follow
sudo xrf logs --export /root/xray-diagnostic.log
sudo xrf check --deep
sudo xrf health
sudo xrf test-sni your-target.example --target your-target.example:443
~~~

The log export option writes a requested diagnostic copy; it does not switch the service to file logging. `XRAY_LOG_LEVEL` controls Xray verbosity. `test-sni` checks the chosen external target and SNI, but does not establish client-to-VPS interoperability.

## Paths and network

`XRF_PREFIX`, `XRF_ETC`, and `XRF_VAR` customize the binary, configuration, and state roots. The default state lives under `/var/lib/xray-fusion`; the systemd unit runs Xray with the active release directory. The tool does not edit host firewall or sysctl settings. Open the configured REALITY port in your own network controls.

For source changes, run `make fmt && make lint && make test-unit`, then relevant integration and Docker lifecycle checks. The host shell is the baseline development environment; `thin-devbox-shell` remains an optional external tool.
