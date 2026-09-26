# Advanced Configuration

## Installation Options

```bash
--topology reality-only|vision-reality  # Deployment mode (required)
--domain <domain>                       # Domain (required for vision-reality)
--version <version>                     # Xray version (default: newest published release)
--plugins <plugin1,plugin2>             # Comma-separated plugin list
--template <template-id>                # Use predefined template
--uuid <uuid>                           # Custom UUID
--enable-vless-encryption               # Enable optional VLESS Encryption for Reality inbound
--vless-decryption <value>              # Custom Reality inbound decryption value
--vless-encryption <value>              # Custom Reality client-link encryption value
--debug                                 # Enable debug logging
```

## Version Policy

- Default `--version latest` selects the newest published, non-draft GitHub
  release by publication time, including prereleases.
- Use an explicit `--version vX.Y.Z` to pin a release. If GitHub's releases API
  fails, the installer fails instead of selecting an older stable release.

## Templates

| Template | Topology | Use Case |
|----------|----------|----------|
| `home` | reality-only | Personal use |
| `office` | vision-reality | Small team (5-20 users) |
| `server` | vision-reality | Production (50+ users) |

```bash
curl -sL install.sh | bash -s -- --template office --domain vpn.company.com
```

## Deployment Modes

### Reality-only
- No domain required
- SNI camouflage (default: `www.apple.com`)
- Port: 443
- Supports optional VLESS Encryption (`decryption` configurable)
- Auto network profile: IPv4-only hosts use `listen: 0.0.0.0` + `dns.queryStrategy: UseIPv4`

### Vision-Reality
- Domain ownership required
- Real TLS + Reality fallback
- Ports: 8443 (Vision), 443 (Reality)
- VLESS Encryption applies to Reality inbound only (Vision remains `decryption: none`)
- Auto network profile: IPv6-capable hosts use dual-stack `listen: ::` + `dns.queryStrategy: UseIP`

## Plugins

| Plugin | Description |
|--------|-------------|
| `cert-auto` | Automatic TLS certificates via Caddy |
| `firewall` | Firewall port management |
| `logrotate-obs` | Log rotation |
| `links-qr` | QR code for client links |

```bash
xrf plugin list
xrf plugin enable cert-auto
xrf plugin info cert-auto
```

## Backup & Restore

```bash
xrf backup create
xrf backup create --name pre-upgrade
xrf backup create --name secure-copy --encrypt
xrf backup create --name secure-copy --encrypt --password-file /root/backup.pass
xrf backup list
xrf backup restore <name>
xrf backup restore <name> --password-file /root/backup.pass
xrf backup verify <name>
```

## Client Export

```bash
xrf export uri
xrf export v2rayn
xrf export clash
xrf export sub
xrf export qr
xrf export all --out-dir /tmp/xrf-export
```

## Environment Variables

```bash
XRAY_SNI=www.apple.com                        # Reality SNI
XRAY_VISION_PORT=8443                         # Vision port
XRAY_REALITY_PORT=443                         # Reality port
XRAY_VLESS_ENCRYPTION_ENABLED=false           # Optional VLESS Encryption switch
XRAY_VLESS_DECRYPTION=<value>                 # Reality inbound decryption value
XRAY_VLESS_ENCRYPTION=<value>                 # Reality link encryption value
CADDY_HTTP_PORT=80                            # ACME challenge
CADDY_HTTPS_PORT=8444                         # Caddy HTTPS
```

## Port Allocation (vision-reality)

| Port | Service |
|------|---------|
| 443 | Reality |
| 8443 | Vision |
| 8444 | Caddy HTTPS |
| 8080 | Caddy fallback |

## Client Requirements

Use a current Xray-core client compatible with the server's configured protocol.
Check the [official releases list](https://github.com/XTLS/Xray-core/releases)
and verify interoperability after upgrading either endpoint.

## Development

```bash
make fmt        # Format
make lint       # Lint
make test-unit  # Test
```
