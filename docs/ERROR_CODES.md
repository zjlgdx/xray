# Error Codes Reference

Xray-Fusion has numeric exit statuses in `lib/errors.sh` and structured `XRF-CATEGORY-NUMBER` messages in `lib/error_codes.sh`. A command may also log a direct error without a structured code. Read the actual message and exit status before choosing a recovery action.

| Structured code | Defined meaning | Next check |
| --- | --- | --- |
| XRF-CONFIG-003 | Required parameter missing | Supply the named current option or required environment input. Fresh install requires `XRAY_SNI`. |
| XRF-CONFIG-004 | Invalid UUID format | Omit `--uuid` for generation or pass an RFC 4122 UUID. |
| XRF-NETWORK-001 | Port conflict | Check the configured listen port with `sudo ss -ltnp`. |
| XRF-XRAY-001 | Xray config test failed | Run the Xray `-test` command against the active managed confdir. |
| XRF-SYSTEM-001 | Required command missing | Install the named dependency and retry. |

These are helper-defined codes, not a promise that every failure uses one. Removed topology, certificate and plugin paths have no current error-code contract. Unknown CLI options fail instead of being translated to retired modes.

## Exit statuses

`lib/errors.sh` defines general, invalid-argument, not-found, permission, configuration, network and timeout errors; validation errors for port, UUID, shortId and version; service start/stop/not-found errors; and file read/write/directory errors. Individual commands may use a narrower set. `xrf help` and command-specific `--help` describe supported options.

## Practical diagnosis

~~~bash
sudo xrf status
sudo xrf check --deep
sudo xrf logs --lines 100
sudo journalctl -u xray.service -n 100 --no-pager
sudo /usr/local/bin/xray -test -confdir /usr/local/etc/xray/active -format json
~~~

Use the configured paths if you set `XRF_PREFIX` or `XRF_ETC`. Journald collects Xray stdout/stderr; no service file-log or logrotate branch exists.

Fresh installation requires a user-selected `XRAY_SNI`. Probe the intended target and SNI with `xrf test-sni <sni> --target <host:port>` before installation. The probe checks TLS 1.3, HTTP/2 and redirects on that exact endpoint. It is advisory; local input and candidate Xray configuration tests are the installation gates.

For an existing managed installation, `sudo xrf upgrade --version latest` is the binary update path. The current `latest` policy includes published prereleases; the verified newest release for this change was v26.9.9. No legacy topology conversion is provided.

State holds complete client credentials and is private (directory 0700, file 0600). Use `sudo xrf links` to read it; do not relax permissions. Backups likewise contain credentials and restore only a valid managed release layout. If rollback fails, retain the private recovery files named by the error.

See [troubleshooting](../TROUBLESHOOTING.md) and [advanced configuration](advanced.md).
