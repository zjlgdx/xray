#!/usr/bin/env bats
# Test lib/defaults.sh - Default configuration values
# shellcheck disable=SC2154  # Variables defined in test_helper.bash

load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/lib/defaults.sh"
}

teardown() {
  cleanup_test_env
}

# === Readonly Constants Tests ===

@test "DEFAULT_XRAY_PORT is 443" {
  [ "${DEFAULT_XRAY_PORT}" = "443" ]
}

@test "no implicit REALITY SNI target is defined" {
  [ -z "${DEFAULT_XRAY_SNI:-}" ]
}

@test "DEFAULT_XRAY_SNIFFING is true" {
  [ "${DEFAULT_XRAY_SNIFFING}" = "true" ]
}

@test "DEFAULT_XRAY_FINGERPRINT is chrome" {
  [ "${DEFAULT_XRAY_FINGERPRINT}" = "chrome" ]
}

@test "DEFAULT_XRF_DEBUG is false" {
  [ "${DEFAULT_XRF_DEBUG}" = "false" ]
}

@test "DEFAULT_VERSION is latest" {
  [ "${DEFAULT_VERSION}" = "latest" ]
}

# === Source Guard Tests ===

@test "defaults.sh can be sourced multiple times without error" {
  # Source the file again (it was already sourced in setup)
  source "${PROJECT_ROOT}/lib/defaults.sh"
  # If we get here, the source guard worked
  [ "${_XRF_DEFAULTS_LOADED}" = "1" ]
}
