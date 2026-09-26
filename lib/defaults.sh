#!/usr/bin/env bash
# Default configuration values for xray-fusion
# This file provides centralized configuration management
# Override via environment variables or command-line arguments

# shellcheck disable=SC2034  # Constants consumed by sourcing modules

# Source guard: prevent double-sourcing (readonly variables cannot be re-declared)
[[ -n "${_XRF_DEFAULTS_LOADED:-}" ]] && return 0
readonly _XRF_DEFAULTS_LOADED=1

# === Port Defaults ===
readonly DEFAULT_XRAY_PORT=443

# === Reality Protocol Defaults ===
readonly DEFAULT_XRAY_SNIFFING="true"
readonly DEFAULT_XRAY_FINGERPRINT="chrome"

# === Logging Defaults ===
readonly DEFAULT_XRF_DEBUG="false"

# === Version Defaults ===
readonly DEFAULT_VERSION="latest"
