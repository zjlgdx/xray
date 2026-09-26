#!/usr/bin/env bash
# UUID generation utilities for xray-fusion
# Provides wrapper around xray uuid with fallback and custom mapping support
# NOTE: This file is sourced. Strict mode is set by core::init() from the calling script

# Source guard: prevent double-sourcing
[[ -n "${_XRF_UUID_LOADED:-}" ]] && return 0
readonly _XRF_UUID_LOADED=1

##
# Generate a random UUID
#
# Uses xray uuid if available (preferred), falls back to uuidgen or
# /proc/sys/kernel/random/uuid. Xray's UUID generator is preferred
# as it uses the same implementation as Xray-core.
#
# Output:
#   UUID string to stdout (e.g., 6ba85179-d64e-4cb8-901f-bfb8e9e7d5f1)
#
# Returns:
#   0 - Success
#   1 - All UUID generation methods failed
#
# Example:
#   uuid=$(uuid::generate)
#   # Output: 6ba85179-d64e-4cb8-901f-bfb8e9e7d5f1
##
uuid::generate() {
  local uuid=""
  local xray_bin="${1:-}"

  # Try xray uuid first (preferred method)
  if [[ -n "${xray_bin}" && -x "${xray_bin}" ]]; then
    uuid=$("${xray_bin}" uuid 2> /dev/null) && [[ -n "${uuid}" ]] && {
      echo "${uuid}"
      return 0
    }
  fi

  # Fallback 1: uuidgen (common on most systems)
  if command -v uuidgen > /dev/null 2>&1; then
    uuid=$(uuidgen 2> /dev/null) && [[ -n "${uuid}" ]] && {
      echo "${uuid}"
      return 0
    }
  fi

  # Fallback 2: /proc/sys/kernel/random/uuid (Linux-specific)
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    uuid=$(cat /proc/sys/kernel/random/uuid 2> /dev/null) && [[ -n "${uuid}" ]] && {
      echo "${uuid}"
      return 0
    }
  fi

  # All methods failed
  core::log error "failed to generate UUID" '{"xray_available":false,"uuidgen_available":false,"proc_uuid_available":false}'
  return 1
}

##
# Generate a UUID from a custom string
#
# Uses xray uuid -i to create a deterministic UUID from a string.
# This allows memorable identifiers (e.g., "alice") to be converted
# to valid UUIDs. The same string always produces the same UUID.
#
# Arguments:
#   $1 - Custom string (required, any string)
#   $2 - Xray binary path (optional, defaults to auto-detect)
#
# Output:
#   UUID string to stdout
#
# Returns:
#   0 - Success
#   1 - xray uuid -i not available or failed
#
# Example:
#   uuid=$(uuid::from_string "alice")
#   # Output: b0d82e7d-4d24-5b5c-9b6e-3c4e1f0a8c9d
#
#   # Same string produces same UUID
#   uuid2=$(uuid::from_string "alice")
#   # Output: b0d82e7d-4d24-5b5c-9b6e-3c4e1f0a8c9d (identical)
##
uuid::from_string() {
  local input_string="${1:?uuid::from_string requires input string}"
  local xray_bin="${2:-}"
  local uuid=""

  # Require xray binary for custom mapping
  if [[ -z "${xray_bin}" ]]; then
    core::log error "xray binary required for UUID custom mapping" '{"feature":"uuid -i","suggestion":"install xray first"}'
    return 1
  fi

  if [[ ! -x "${xray_bin}" ]]; then
    core::log error "xray binary not executable" "$(printf '{"path":"%s"}' "${xray_bin}")"
    return 1
  fi

  # Generate UUID from string using xray uuid -i
  uuid=$("${xray_bin}" uuid -i "${input_string}" 2> /dev/null)

  if [[ -z "${uuid}" ]]; then
    core::log error "xray uuid -i failed" "$(printf '{"input":"%s"}' "${input_string}")"
    return 1
  fi

  echo "${uuid}"
  return 0
}
