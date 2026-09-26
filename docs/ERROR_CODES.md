# Error Codes Reference

Commands report errors through `core::log` and numeric exit statuses. Read the message and exit status together; there is no separate structured error-code API. Unknown CLI options fail instead of being translated to retired modes.

## Exit statuses

`lib/errors.sh` defines `ERR_INVALID_ARG=2`, used by managed configuration input validation. Commands also return ordinary shell success/failure statuses; no universal numeric taxonomy is promised. `xrf help` and command-specific `--help` describe supported options.

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
