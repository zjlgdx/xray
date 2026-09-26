# Xray-Fusion Test Suite

Bats tests cover current REALITY installation, configuration, upgrade, backup, diagnostic, and uninstall behavior. Host shell runs are the development baseline. Fresh Docker containers provide the separate Linux lifecycle smoke.

## Commands

~~~bash
make check-bats-runtime
make test-unit
make test-integration
make test
bats -t tests/unit/test_backup_restore_contract.bats
bash scripts/e2e/install-lifecycle-smoke.sh
~~~

The smoke uses the official Xray binary selected by the shared version resolver (default `latest`, including published prereleases) and a deliberate test-only SNI. It checks fresh install, reinstall refusal, uninstall/reinstall, backup and restore after a controlled config change, custom paths, and `xray -test` as the service user. It mocks systemctl, so it does not establish real service activation or client interoperability. The newest release verified for this work was v26.9.9.

An online wrapper smoke can be run against a pushed branch:

~~~bash
XRF_SMOKE_MODE=online \
XRF_SMOKE_BRANCH=<branch> \
XRF_SMOKE_INSTALL_URL="https://raw.githubusercontent.com/zjlgdx/xray/<branch>/install.sh" \
XRF_SMOKE_UNINSTALL_URL="https://raw.githubusercontent.com/zjlgdx/xray/<branch>/uninstall.sh" \
bash scripts/e2e/install-lifecycle-smoke.sh
~~~

The default repository is `https://github.com/zjlgdx/xray.git`. Use the host Docker daemon; do not assume Docker works inside an optional devbox container.

## Test areas

- `unit/test_reality_install_contract.bats` and `integration/test_install_flow.bats`: current single REALITY inbound, Vision flow, raw transport, explicit SNI, private state, service activation, and shared install lock.
- `unit/test_upgrade.bats`, `unit/test_upgrade_running_binary.bats`, and `unit/test_deploy_transaction.bats`: candidate validation, config preservation, process verification, and bounded rollback.
- `unit/test_backup_restore_contract.bats` plus backup/command tests: managed archive validation, credentials and digest requirements, shared lock, stopped/active state, and recovery on failure.
- `unit/test_client_links.bats`: VLESS URI output and denial for users without private state access.
- `unit/test_test_sni_command.bats`: consistent host:port/SNI checks for TLS 1.3, HTTP/2, and redirects.
- `integration/test_uninstall_idempotent.bats`: missing-target uninstall twice.

Retired plugin, template, dual-topology, Caddy, certificate, firewall, sysctl, and standalone client-export tests were removed with those production paths. The supported `xrf logs --export` diagnostic option remains distinct from the removed standalone `xrf export` command.

## Evidence boundaries

The runtime-payload cleanup on 2026-09-26 recorded 854 unit passes with 16 skips and 32 integration passes with 1 skip on the macOS host. A fresh Ubuntu 24.04 container also passed ShellCheck on the installer and the online-wrapper Bats suite (28 passed, 1 skipped); these wrapper tests use mocked services. The preceding REALITY-only change recorded five fresh Ubuntu Docker lifecycle scenarios with official v26.9.9; those Docker scenarios were not rerun for this cleanup. Check GitHub Actions on the corresponding PR and commit for its actual CI result; local validation does not establish that CI ran. Do not describe local mocks as a real systemd or client connection test.

## Bats and coverage setup

Install bats-core, ShellCheck, shfmt, jq, and optional kcov with your host package manager. Minimal Linux containers also need a readable `/dev/fd/0`; restore `/dev/fd` with `sudo ln -sf /proc/self/fd /dev/fd` if bats fails before running tests. For real shell coverage, use `make coverage-unit-real` or `make coverage-real`. These local Make targets report coverage percentages; CI reads `.github/coverage/unit-threshold.txt` and enforces the unit threshold. Integration coverage is reported separately. If kcov exits nonzero because of a bats DEBUG-trap conflict, inspect `coverage.json` before drawing a conclusion.

For isolated tests, use `setup_test_env`/`cleanup_test_env` from `tests/test_helper.bash`. Name behavior and fault cases explicitly, keep mocks narrow, and call production functions for lifecycle claims. When a shell test file is new and untracked, run ShellCheck explicitly because the Makefile lint file list comes from tracked files.

## Retired helper coverage

Tests follow production entry points. Unused dependency/plugin installers, structured error-message helpers, VLESS encryption validators, and duplicate utility APIs have been removed together with their isolated tests. UUID generation still validates its output through the shared validator; core initialization still checks actual shell options. Lifecycle, rollback, credential protection, and configuration validation tests remain in scope.

Online-wrapper tests verify that `--help` needs no temporary directory and that
the deployed runtime omits development files while retaining runnable commands,
the systemd unit, and the license. Wrapper lifecycle tests still cover repeat
installation refusal, uninstall/reinstall, and failure cleanup.
