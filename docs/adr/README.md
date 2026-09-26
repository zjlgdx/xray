# Architecture Decision Records (ADR)

This directory contains Architecture Decision Records for the xray-fusion project.
The dates and accepted statuses record decisions at the time. Certificate sync,
Caddy, plugin, dual-topology, and older-version reviews are historical; they do
not describe the current REALITY-only product. Use the root README and current
configuration verification document for present behavior.

## Index

| ADR | Title | Date | Status |
|-----|-------|------|--------|
| [001](./001-unified-parameter-system.md) | Unified Parameter Passing System | 2025-09 | Accepted |
| [002](./002-timer-over-path-unit.md) | Certificate Sync: Timer over Path Unit | 2025-10-05 | Accepted |
| [003](./003-xray-restart-not-reload.md) | Xray Uses restart Instead of reload | 2025-10-05 | Accepted |
| [004](./004-ecdsa-certificate-support.md) | Certificate Validation Supports ECDSA | 2025-10-05 | Accepted |
| [005](./005-remove-ocsp-stapling.md) | Remove OCSP Stapling | 2025-10-06 | Accepted |
| [006](./006-certificate-sync-locking.md) | Certificate Sync Concurrency Lock | 2025-10-06 | Accepted |
| [007](./007-mandatory-config-validation.md) | Mandatory Configuration Validation | 2025-10-06 | Accepted |
| [008](./008-cert-sync-script-extraction.md) | Certificate Sync Script Independence | 2025-11-09 | Accepted |
| [009](./009-bats-testing-framework.md) | Automated Testing with bats-core | 2025-11-09 | Accepted |
| [010](./010-phase1-security-enhancements.md) | Phase 1 Security Enhancements | 2025-11-10 | Accepted |
| [011](./011-xray-v25-review.md) | Xray v25.12.8 Updates Review | 2025-12-09 | Accepted |
| [012](./012-xray-v26-review.md) | Xray v26.1.23 Updates Review | 2026-01-24 | Accepted |
| [013](./013-xray-v26.2.6-review.md) | Xray v26.2.6 Alignment and Forward Compatibility | 2026-02-28 | Accepted |
| [014](./014-kcov-bats-coverage.md) | kcov Coverage for Bash with bats-core | 2026-03-03 | Accepted |
| [015](./015-xray-v26.3.27-review.md) | Xray v26.3.27 Compatibility Review | 2026-04-06 | Accepted |

## ADR Format

Each ADR follows this structure:
- **Problem**: What issue prompted this decision?
- **Decision**: What was decided?
- **Rationale**: Why was this the best choice?
- **Impact** (optional): What changed as a result?
