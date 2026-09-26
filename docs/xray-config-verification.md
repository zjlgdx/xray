# Xray Configuration Verification

This document describes the current generated server configuration and the evidence available on 2026-09-26. The earlier v26.2.6 dual-topology verification is historical and no longer describes this product.

## Managed configuration

A fresh install renders one VLESS inbound with the Vision flow (`xtls-rprx-vision`), `decryption: none`, `streamSettings.network: raw`, and `security: reality`. REALITY settings use `target`, `serverNames`, `privateKey`, and a shortId pool. No separate TLS inbound, certificate, Caddy fallback, plugin, template, or optional VLESS-encryption mode is generated. The client URI contains the corresponding Vision flow, public key, selected shortId, SNI, fingerprint and address.

`XRAY_SNI` is required and has no built-in site default. If `XRAY_REALITY_DEST` is omitted, target is `<XRAY_SNI>:443`. Before installation, operators should probe the intended host:port and SNI for TLS 1.3, HTTP/2 and no redirect using `xrf test-sni`. The probe is advisory because external reachability can change. Installation hard-validates input and the candidate Xray configuration.

Xray access/error output uses stdout/stderr and systemd journald. Config and service files are readable by the Xray service user; complete connection credentials remain in root-private state (directory 0700, file 0600). The service user successfully ran the Xray `-test` check in the isolated Ubuntu lifecycle smoke.

## Version and source evidence

The shared `latest` resolver selects the newest published non-draft official Xray-core release by publication time, including prereleases. The newest release verified for this work was [v26.9.9](https://github.com/XTLS/Xray-core/releases/tag/v26.9.9), a prerelease. Product defaults do not pin that tag. Official [REALITY examples](https://github.com/XTLS/REALITY/blob/main/README.md#vless-xtls-utls-reality-example-for-xray-core) and the [v26.9.9 transport parser](https://github.com/XTLS/Xray-core/blob/v26.9.9/infra/conf/transport_internet.go#L14-L81) support the selected raw transport and Vision flow. The [Xray log reference](https://xtls.github.io/en/config/log.html) documents stdout behavior when access/error paths are empty or omitted.

## Verification completed for this change

- Local unit suite: 977 passed, 16 skipped.
- Local integration suite: 28 passed, 1 skipped.
- Fresh Ubuntu Docker lifecycle: five scenarios passed using the actual official v26.9.9 binary, including Xray configuration testing as the xray service user, reinstall refusal, backup/restore, and custom paths. The lifecycle test substitutes a systemctl mock.
- Restore fault tests exercise archive validation, pre-restore backup failure, active/stopped service handling, and bounded rollback.
- The SNI diagnostic checks one explicit target host:port/SNI pair across TLS 1.3, HTTP/2 and redirect probes.

These results do not prove that a real systemd manager started the service on a target VPS, that a particular external target remains suitable, or that a real client completed a connection. There was no production deployment in this work; run an actual client-through-VPS test and inspect the effective service/journal on the target host before claiming interoperability.

## Configuration checks

~~~bash
sudo xrf check --deep
sudo /usr/local/bin/xray -test -confdir /usr/local/etc/xray/active -format json
sudo xrf status
sudo xrf links
sudo xrf logs --lines 100
~~~

Use configured paths when `XRF_PREFIX` or `XRF_ETC` differs. The `links` command requires access to private state. Existing managed installations use `xrf upgrade` for binary changes; legacy or unknown configuration formats are not accepted as an automatic migration path.
