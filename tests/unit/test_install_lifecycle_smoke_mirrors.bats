#!/usr/bin/env bats
# Regression tests for e2e install lifecycle smoke mirror fallbacks.

load '../test_helper'

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

smoke_mirror_block() {
  awk '/^[[:space:]]*local mirrors=\(/,/^[[:space:]]*\)/ { print }' \
    "${PROJECT_ROOT}/scripts/e2e/install-lifecycle-smoke.sh"
}

has_https_fallback_mirror() {
  smoke_mirror_block | grep -Eq '"https://mirrors\.[^"]+"'
}

has_http_fallback_mirror() {
  smoke_mirror_block | grep -Eq '"http://mirrors\.[^"]+"'
}

has_resolved_xray_version_install() {
  local script="${PROJECT_ROOT}/scripts/e2e/install-lifecycle-smoke.sh"
  grep -q "resolve_smoke_xray_version" "${script}" &&
    grep -Eq -- '--version .*SMOKE_XRAY_VERSION' "${script}"
}

has_online_pipefail_guard() {
  local script="${PROJECT_ROOT}/scripts/e2e/install-lifecycle-smoke.sh"
  grep -q "set -o pipefail; export XRF_REPO_URL" "${script}"
}

@test "install lifecycle smoke mirror fallbacks include HTTPS mirrors" {
  run has_https_fallback_mirror
  [ "${status}" -eq 0 ]
}

@test "install lifecycle smoke mirror fallbacks include HTTP mirrors" {
  run has_http_fallback_mirror
  [ "${status}" -eq 0 ]
}

@test "install lifecycle smoke installs with a resolved xray version" {
  run has_resolved_xray_version_install

  [ "${status}" -eq 0 ]
}

@test "install lifecycle smoke resolves through the shared releases-list helper" {
  local script="${PROJECT_ROOT}/scripts/e2e/install-lifecycle-smoke.sh"
  grep -Fq 'services/xray/install_utils.sh' "${script}"
  grep -Fq 'xray::resolve_latest_tag' "${script}"
  run grep -Fq '/releases/latest' "${script}"
  [ "$status" -ne 0 ]
}

@test "install lifecycle smoke online curl pipelines enable pipefail" {
  run has_online_pipefail_guard

  [ "${status}" -eq 0 ]
}
