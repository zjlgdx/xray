# Troubleshooting Guide

Common issues and solutions for xray-fusion deployment and operation.

## Table of Contents

- [Installation Issues](#installation-issues)
- [Certificate Issues](#certificate-issues)
- [Service Issues](#service-issues)
- [Connection Issues](#connection-issues)
- [Plugin Issues](#plugin-issues)
- [Debugging Tips](#debugging-tips)

---

## Installation Issues

### Issue: "Invalid topology" error

**Symptom**: Installation fails with error message about invalid topology.

**Cause**: Unsupported topology value provided via --topology flag.

**Solution**:
```bash
# Only these topologies are supported:
bin/xrf install --topology reality-only      # ✅ Valid
bin/xrf install --topology vision-reality    # ✅ Valid (requires --domain)
bin/xrf install --topology other             # ❌ Invalid
```

**Related**: services/xray/configure.sh:295

---

### Issue: "vision-reality requires domain" error

**Symptom**: Installation fails when using vision-reality topology without domain.

**Cause**: Vision topology requires real TLS certificates, which need a domain name.

**Solution**:
```bash
# Provide domain with vision-reality
bin/xrf install --topology vision-reality --domain your.domain.com --plugins cert-auto
```

**Related**: lib/args.sh cross-validation

---

### Issue: "Domain validation failed" error

**Symptom**: Installation rejects domain name.

**Possible Causes**:
1. Using private/internal IP addresses
2. Using special-use TLDs (.test, .invalid)
3. Using localhost or .local domains
4. Using link-local addresses

**Solution**:
```bash
# ❌ These will be rejected:
--domain 192.168.1.1      # RFC 1918 private network
--domain 169.254.1.1      # RFC 3927 link-local
--domain example.test     # RFC 6761 special-use TLD
--domain localhost        # Loopback
--domain ::1              # IPv6 loopback
--domain fc00::1          # IPv6 unique local address

# ✅ Use public domain names:
--domain example.com
--domain subdomain.yourdomain.com
```

**Related**: lib/validators.sh:42 (validators::domain)

---

## Certificate Issues

### Issue: Certificate sync fails with permission errors

**Symptom**: `caddy-cert-sync` logs permission denied errors.

**Cause**: Lock file created by previous root run, cannot be written by non-root user.

**Solution**:
```bash
# Fix lock file ownership
sudo chown $(id -u):$(id -g) /var/lib/xray-fusion/locks/caddy-cert-sync.lock
sudo chmod 0644 /var/lib/xray-fusion/locks/caddy-cert-sync.lock

# Or remove and recreate
sudo rm -f /var/lib/xray-fusion/locks/caddy-cert-sync.lock
```

**Prevention**: The script now automatically fixes ownership (Phase 1 improvements).

**Related**: scripts/caddy-cert-sync.sh:59-70, CWE-283

---

### Issue: "certificate and private key do not match" error

**Symptom**: Certificate sync aborts with validation error.

**Cause**: Certificate and private key files are from different pairs.

**Diagnosis**:
```bash
# Check certificate and key match
cert_hash=$(openssl x509 -in cert.pem -pubkey -noout | sha256sum)
key_hash=$(openssl pkey -in key.pem -pubout | sha256sum)
echo "Cert: $cert_hash"
echo "Key:  $key_hash"
# Should be identical
```

**Solution**:
- Ensure you're using matching certificate and key files
- Re-request certificate if necessary
- Check Caddy logs for certificate renewal issues

**Related**: scripts/caddy-cert-sync.sh:165-188

---

### Issue: "certificate has already expired" error

**Symptom**: Certificate sync refuses to install expired certificate.

**Cause**: Caddy failed to renew certificate before expiration.

**Diagnosis**:
```bash
# Check certificate expiration
openssl x509 -in /root/.local/share/caddy/certificates/*/your.domain.com/your.domain.com.crt -noout -dates

# Check Caddy logs
journalctl -u caddy -n 100 | grep -i renew
```

**Solution**:
```bash
# Force Caddy certificate renewal
systemctl restart caddy

# Wait for renewal (check logs)
journalctl -u caddy -f

# Manually trigger sync after renewal
/usr/local/bin/caddy-cert-sync your.domain.com
```

**Related**: scripts/caddy-cert-sync.sh:154

---

### Issue: Certificate sync finds no certificates

**Symptom**: "certificate file not found for DOMAIN" error.

**Cause**: Caddy hasn't obtained certificates yet or certificates are in unexpected location.

**Diagnosis**:
```bash
# Check if Caddy certificates exist
find /root/.local/share/caddy/certificates -name "your.domain.com.crt"

# Check Caddy is running and configured
systemctl status caddy
journalctl -u caddy -n 50
```

**Solution**:
```bash
# Wait for Caddy to obtain certificates (can take a few minutes)
journalctl -u caddy -f

# Verify domain DNS points to your server
dig your.domain.com

# Check Caddy can bind to required ports
ss -tlnp | grep -E ':(80|443)'
```

**Related**: scripts/caddy-cert-sync.sh:138-148

---

## Service Issues

### Issue: Xray service fails to start

**Symptom**: `systemctl status xray` shows failed status.

**Diagnosis**:
```bash
# Check Xray service status
systemctl status xray

# View detailed logs
journalctl -u xray -n 50 --no-pager

# Test Xray configuration
/usr/local/bin/xray -test -confdir /usr/local/etc/xray/active
```

**Common Causes**:

1. **Invalid Configuration**
   ```bash
   # Solution: Check config test output
   /usr/local/bin/xray -test -confdir /usr/local/etc/xray/active -format json
   ```

2. **Port Already in Use**
   ```bash
   # Check what's using the port
   ss -tlnp | grep ':443'

   # Solution: Stop conflicting service or change Xray port
   ```

3. **Missing Certificates** (vision-reality only)
   ```bash
   # Check certificates exist
   ls -la /usr/local/etc/xray/certs/

   # Solution: Wait for cert-auto plugin to obtain certificates
   ```

**Related**: services/xray/install.sh, packaging/systemd/

---

### Issue: Certificate reload timer not triggering

**Symptom**: New certificates not being synced to Xray.

**Diagnosis**:
```bash
# Check timer status
systemctl status cert-reload.timer
systemctl list-timers cert-reload.timer

# Check if service is enabled
systemctl is-enabled cert-reload.timer

# View timer logs
journalctl -u cert-reload.service -n 20
```

**Solution**:
```bash
# Enable timer if not enabled
sudo systemctl enable --now cert-reload.timer

# Manually trigger sync for testing
sudo systemctl start cert-reload.service

# Check timer schedule
systemctl cat cert-reload.timer
```

**Related**: ADR-002, packaging/systemd/cert-reload.timer

---

## Connection Issues

### Issue: Connection fails or frequent disconnects

**Symptom**: Client cannot connect, or connections drop frequently.

**Possible Cause**: Outdated Xray client version with known bugs.

**Diagnosis**:
```bash
# Check client version
xray version
```

**Known Version Issues**:
- **v25.9.5 - v25.10.14**: uTLS library bug affecting Chrome fingerprint simulation
- **< v1.8.0**: Incompatible protocol versions

**Solution**:

1. **Upgrade the client to a current published Xray release**: choose the newest
   published tag from the [official releases list](https://github.com/XTLS/Xray-core/releases),
   which can include prereleases. Download the archive and `.dgst` checksum for
   your platform, verify them, and follow your client's update procedure. For a
   server managed by xray-fusion, `sudo xrf upgrade --version latest` uses the
   newest published, non-draft release.

2. **Verify client configuration**:
   - Ensure UUID matches server configuration
   - Check fingerprint is set to "chrome"
   - Verify flow is "xtls-rprx-vision"

3. **Check client logs**:
   ```bash
   xray run -c config.json
   ```

**Recommended Client Versions**:
| Version | Status |
|---------|--------|
| v25.10.15+ | ✅ Recommended (includes uTLS fix) |
| v25.9.5 - v25.10.14 | ⚠️ May have issues |
| v1.8.0 - v25.9.4 | ✅ Supported |
| < v1.8.0 | ❌ Not supported |

**Official Downloads**: https://github.com/XTLS/Xray-core/releases

**Related**: v25.10.15 Release Notes, ADR-011

---

### Issue: Cannot connect to Reality endpoint

**Symptom**: Client connection timeout or refused.

**Diagnosis**:
```bash
# Test port accessibility
timeout 3 bash -c "</dev/tcp/YOUR_SERVER_IP/443" && echo "Port 443 accessible"

# Check Xray is listening
ss -tlnp | grep xray

# Check firewall rules
sudo ufw status
sudo iptables -L -n | grep 443
```

**Solution**:
```bash
# Ensure firewall allows traffic
sudo ufw allow 443/tcp

# Verify Xray is running
systemctl status xray

# Check server_name matches client configuration
# Client SNI must match XRAY_SNI value (default: www.apple.com)
```

**Related**: Reality protocol configuration

---

### Issue: Vision endpoint connection fails

**Symptom**: VLESS+Vision connection timeout (port 8443).

**Cause**: Missing TLS certificates or firewall blocking port.

**Diagnosis**:
```bash
# Check Vision port accessibility
timeout 3 bash -c "</dev/tcp/YOUR_DOMAIN/8443" && echo "Port 8443 accessible"

# Verify certificates exist
ls -la /usr/local/etc/xray/certs/

# Check Xray logs
journalctl -u xray -f
```

**Solution**:
```bash
# Ensure certificates are synced
sudo /usr/local/bin/caddy-cert-sync your.domain.com

# Allow port in firewall
sudo ufw allow 8443/tcp

# Restart Xray
sudo systemctl restart xray
```

**Related**: Vision+Reality topology, port 8443

---

## Plugin Issues

### Issue: "Plugin not found" error

**Symptom**: `bin/xrf plugin enable plugin-name` fails.

**Cause**: Plugin does not exist in plugins/available/.

**Solution**:
```bash
# List available plugins
bin/xrf plugin list

# Check plugin exists
ls -la plugins/available/

# Use correct plugin ID (e.g., 'cert-auto', not 'cert')
bin/xrf plugin enable cert-auto
```

**Related**: lib/plugins.sh:127

---

### Issue: Plugin hook execution fails

**Symptom**: Installation succeeds but plugin functionality missing.

**Diagnosis**:
```bash
# Enable debug logging
XRF_DEBUG=true bin/xrf install --topology reality-only --plugins firewall

# Check plugin is enabled
ls -la plugins/enabled/

# Verify plugin metadata
cat plugins/available/firewall/plugin.sh | grep XRF_PLUGIN
```

**Solution**:
- Check plugin logs in debug output
- Verify plugin dependencies are installed
- Ensure plugin has correct permissions (executable)

**Related**: lib/plugins.sh, plugin hook system

---

## Debugging Tips

### Enable Debug Logging

```bash
# Install with debug output
XRF_DEBUG=true bin/xrf install --topology reality-only

# Use JSON format for structured logging
XRF_JSON=true bin/xrf install --topology reality-only

# Combine both
XRF_DEBUG=true XRF_JSON=true bin/xrf install --topology reality-only
```

**Related**: lib/core.sh:111-142 (core::log)

---

### Check Service Logs

```bash
# View recent Xray logs
journalctl -u xray -n 50

# Follow logs in real-time
journalctl -u xray -f

# View logs from specific time
journalctl -u xray --since "10 minutes ago"

# Check certificate sync logs
journalctl -u cert-reload.service -n 20
```

---

### Validate Configuration

```bash
# Test Xray configuration before deployment
/usr/local/bin/xray -test -confdir /usr/local/etc/xray/active

# Check configuration JSON syntax
jq . /usr/local/etc/xray/active/05_inbounds.json

# View active configuration
cat /usr/local/etc/xray/active/*.json | jq -s 'add'
```

**Related**: services/xray/configure.sh:249

---

### Test Lock File Behavior

```bash
# Test lock file creation
ls -la /var/lib/xray-fusion/locks/

# Check lock file ownership
stat /var/lib/xray-fusion/locks/*.lock

# Test concurrent execution protection
/usr/local/bin/caddy-cert-sync your.domain.com &
/usr/local/bin/caddy-cert-sync your.domain.com
# Second instance should skip with "another sync process is running"
```

**Related**: lib/core.sh:180 (core::with_flock), scripts/caddy-cert-sync.sh:74

---

### Network Diagnostics

```bash
# Check listening ports
ss -tlnp | grep xray

# Test port accessibility from external
nc -zv YOUR_SERVER_IP 443
nc -zv YOUR_DOMAIN 8443

# Check DNS resolution
dig your.domain.com
nslookup your.domain.com

# Verify firewall rules
sudo ufw status verbose
sudo iptables -L -n -v | grep -E '(443|8443)'
```

---

## Common Error Messages

| Error Message | Likely Cause | Solution |
|---------------|--------------|----------|
| `invalid directory path` | Path contains `..` or `//` | Use absolute path without parent references |
| `XRAY_PRIVATE_KEY required` | Missing Reality private key | Regenerate with `xray x25519` |
| `invalid topology` | Unsupported topology value | Use `reality-only` or `vision-reality` |
| `vision-reality requires TLS certificates` | Missing cert files | Use `--plugins cert-auto` or install certs manually |
| `certificate file not found` | Caddy hasn't obtained certs yet | Wait for Caddy or check DNS/firewall |
| `lock file creation failed` | Permission or filesystem issue | Check /var/lib/xray-fusion/locks/ permissions |

---

## Getting Help

If you encounter issues not covered in this guide:

1. **Check logs** with debug mode enabled: `XRF_DEBUG=true`
2. **Review documentation**: AGENTS.md, CLAUDE.md, README.md
3. **Search GitHub issues**: https://github.com/xrf9268-hue/xray/issues
4. **Create new issue** with:
   - Output of `bin/xrf status`
   - Relevant logs from `journalctl`
   - Steps to reproduce
   - Environment details (OS, version, etc.)

---

## Prevention Best Practices

- **Always use domain validation**: Don't bypass input validation
- **Monitor certificate expiration**: Set up alerts for certificates expiring within 14 days
- **Test in staging first**: Use a test domain before deploying to production
- **Keep backups**: Backup `/usr/local/etc/xray/` and `/var/lib/xray-fusion/`
- **Use debug mode for testing**: `XRF_DEBUG=true` helps diagnose issues early
- **Check logs regularly**: Review `journalctl -u xray` and `journalctl -u cert-reload.service`
