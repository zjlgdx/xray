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

@test "DEFAULT_XRAY_LOG_LEVEL is warning" {
  [ "${DEFAULT_XRAY_LOG_LEVEL}" = "warning" ]
}

@test "DEFAULT_XRF_DEBUG is false" {
  [ "${DEFAULT_XRF_DEBUG}" = "false" ]
}

@test "DEFAULT_XRF_JSON is false" {
  [ "${DEFAULT_XRF_JSON}" = "false" ]
}

@test "DEFAULT_VERSION is latest" {
  [ "${DEFAULT_VERSION}" = "latest" ]
}

# === Path Functions Tests ===

@test "defaults::xrf_prefix returns default /usr/local" {
  unset XRF_PREFIX
  result="$(defaults::xrf_prefix)"
  [ "${result}" = "/usr/local" ]
}

@test "defaults::xrf_prefix respects XRF_PREFIX env var" {
  export XRF_PREFIX="/custom/prefix"
  result="$(defaults::xrf_prefix)"
  [ "${result}" = "/custom/prefix" ]
}

@test "defaults::xrf_etc returns default /usr/local/etc" {
  unset XRF_ETC
  result="$(defaults::xrf_etc)"
  [ "${result}" = "/usr/local/etc" ]
}

@test "defaults::xrf_etc respects XRF_ETC env var" {
  export XRF_ETC="/custom/etc"
  result="$(defaults::xrf_etc)"
  [ "${result}" = "/custom/etc" ]
}

@test "defaults::xrf_var returns default /var/lib/xray-fusion" {
  unset XRF_VAR
  result="$(defaults::xrf_var)"
  [ "${result}" = "/var/lib/xray-fusion" ]
}

@test "defaults::xrf_var respects XRF_VAR env var" {
  export XRF_VAR="/custom/var"
  result="$(defaults::xrf_var)"
  [ "${result}" = "/custom/var" ]
}

@test "defaults::xrf_lock_dir returns correct path" {
  unset XRF_VAR
  result="$(defaults::xrf_lock_dir)"
  [ "${result}" = "/var/lib/xray-fusion/locks" ]
}

@test "defaults::xrf_lock_dir uses custom XRF_VAR" {
  export XRF_VAR="/custom/var"
  result="$(defaults::xrf_lock_dir)"
  [ "${result}" = "/custom/var/locks" ]
}

# === defaults::get Tests ===

@test "defaults::get returns env var value when set" {
  export XRAY_PORT="8080"
  result="$(defaults::get XRAY_PORT)"
  [ "${result}" = "8080" ]
}

@test "defaults::get returns default value when env var not set" {
  unset XRAY_LOG_LEVEL
  result="$(defaults::get XRAY_LOG_LEVEL)"
  [ "${result}" = "warning" ]
}

@test "defaults::get returns empty for unknown variable" {
  unset UNKNOWN_VAR
  result="$(defaults::get UNKNOWN_VAR)"
  [ "${result}" = "" ]
}

@test "defaults::get prefers env var over default" {
  export XRAY_SNI="custom.example.com"
  result="$(defaults::get XRAY_SNI)"
  [ "${result}" = "custom.example.com" ]
}

# === Source Guard Tests ===

@test "defaults.sh can be sourced multiple times without error" {
  # Source the file again (it was already sourced in setup)
  source "${PROJECT_ROOT}/lib/defaults.sh"
  # If we get here, the source guard worked
  [ "${_XRF_DEFAULTS_LOADED}" = "1" ]
}
