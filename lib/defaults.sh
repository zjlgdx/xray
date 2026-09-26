#!/usr/bin/env bash
# Default configuration values for xray-fusion
# This file provides centralized configuration management
# Override via environment variables or command-line arguments

# shellcheck disable=SC2034  # Variables used via indirect expansion in defaults::get()

# Source guard: prevent double-sourcing (readonly variables cannot be re-declared)
[[ -n "${_XRF_DEFAULTS_LOADED:-}" ]] && return 0
readonly _XRF_DEFAULTS_LOADED=1

# === Port Defaults ===
readonly DEFAULT_XRAY_PORT=443

# === Reality Protocol Defaults ===
readonly DEFAULT_XRAY_SNIFFING="true"
readonly DEFAULT_XRAY_FINGERPRINT="chrome"

# === Logging Defaults ===
readonly DEFAULT_XRAY_LOG_LEVEL="warning"
readonly DEFAULT_XRF_DEBUG="false"
readonly DEFAULT_XRF_JSON="false"

# === Version Defaults ===
readonly DEFAULT_VERSION="latest"

# === Path Defaults (can be overridden via environment variables) ===
defaults::xrf_prefix() { echo "${XRF_PREFIX:-/usr/local}"; }
defaults::xrf_etc() { echo "${XRF_ETC:-/usr/local/etc}"; }
defaults::xrf_var() { echo "${XRF_VAR:-/var/lib/xray-fusion}"; }
defaults::xrf_lock_dir() { echo "$(defaults::xrf_var)/locks"; }

# === Helper: Get value with fallback ===
# Usage: defaults::get VARIABLE_NAME
# Returns: Environment variable value if set, otherwise default value
defaults::get() {
  local key="${1}"
  local default_var="DEFAULT_${key}"
  local env_value="${!key:-}"

  if [[ -n "${env_value}" ]]; then
    echo "${env_value}"
  else
    echo "${!default_var:-}"
  fi
}
