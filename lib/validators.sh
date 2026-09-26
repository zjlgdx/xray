#!/usr/bin/env bash
# Input validation utilities
# Provides RFC-compliant validators for domains, ports, UUIDs, and other inputs
# NOTE: This file is sourced. Strict mode is set by the calling script or core::init()

# Source guard: prevent double-sourcing
[[ -n "${_XRF_VALIDATORS_LOADED:-}" ]] && return 0
readonly _XRF_VALIDATORS_LOADED=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/core.sh
. "${HERE}/lib/core.sh"

##
# Validate hostname (public domain or hostname)
#
# Ensures the hostname is RFC-compliant and free of unsafe characters that
# could break JSON rendering or shell execution.
#
# Arguments:
#   $1 - Hostname (string, required)
#
# Returns:
#   0 - Valid hostname
#   1 - Invalid hostname
##
validators::hostname() {
  local host="${1:-}"

  if [[ -z "${host}" ]]; then
    core::log debug "hostname validation failed: empty" "{}"
    return 1
  fi

  if [[ "${host}" =~ [\"{}[:space:]] ]]; then
    core::log debug "hostname validation failed: unsafe characters" "$(printf '{"hostname":"%s"}' "${host}")"
    return 1
  fi

  if ! validators::domain "${host}"; then
    core::log debug "hostname validation failed: domain check" "$(printf '{"hostname":"%s"}' "${host}")"
    return 1
  fi

  return 0
}

##
# Validate domain name (RFC 1035 compliant)
#
# Validates domain names according to DNS specifications and rejects
# internal/private addresses. Enforces RFC 1035, RFC 1918, RFC 3927,
# RFC 4193, RFC 4291, and RFC 6761 compliance.
#
# Arguments:
#   $1 - Domain name (string, required)
#
# Returns:
#   0 - Valid public domain name
#   1 - Invalid domain (empty, malformed, private, or special-use)
#
# Security:
#   - Rejects RFC 1918 private networks (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
#   - Rejects RFC 3927 link-local addresses (169.254.0.0/16)
#   - Rejects RFC 6761 special-use TLDs (.test, .invalid)
#   - Rejects IPv6 private addresses (::1, fc00::/7, fe80::/10)
#   - Prevents use of localhost and .local domains
#
# Validation Rules:
#   - Total length <= 253 characters (DNS limit)
#   - Each label <= 63 characters
#   - Labels must start/end with alphanumeric (no leading/trailing hyphens)
#   - Only alphanumeric characters and hyphens allowed
#
# Example:
#   validators::domain "example.com"      # Valid
#   validators::domain "192.168.1.1"     # Invalid (private)
#   validators::domain "test.invalid"    # Invalid (RFC 6761)
##
validators::domain() {
  local domain="${1:-}"

  # Empty check
  if [[ -z "${domain}" ]]; then
    core::log debug "domain validation failed: empty" "{}"
    return 1
  fi

  # Length check (DNS specification: total length <= 253)
  if [[ ${#domain} -gt 253 ]]; then
    core::log debug "domain validation failed: length exceeds 253" "$(printf '{"domain":"%s","length":%d}' "${domain}" ${#domain})"
    return 1
  fi

  # Check each label length (DNS specification: label <= 63)
  local IFS='.'
  local labels
  read -ra labels <<< "$domain"
  for label in "${labels[@]}"; do
    if [[ ${#label} -gt 63 ]]; then
      core::log debug "domain validation failed: label exceeds 63" "$(printf '{"label":"%s","length":%d}' "${label}" ${#label})"
      return 1
    fi
  done

  # RFC 1035 compliant regex
  # - Labels must start and end with alphanumeric
  # - Labels can contain hyphens in the middle
  # - Labels are separated by dots
  if [[ ! "${domain}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    core::log debug "domain validation failed: RFC format" "$(printf '{"domain":"%s"}' "${domain}")"
    return 1
  fi

  # Reject internal/private domains and special-use domain names

  # IPv4 private addresses (RFC 1918 + RFC 3927)
  case "${domain}" in
    # Loopback and special addresses
    localhost | *.local | 127.* | 0.0.0.0)
      core::log debug "domain validation failed: loopback/local" "$(printf '{"domain":"%s"}' "${domain}")"
      return 1
      ;;
    # RFC 1918 private networks
    10.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[0-1].* | 192.168.*)
      core::log debug "domain validation failed: RFC 1918 private network" "$(printf '{"domain":"%s"}' "${domain}")"
      return 1
      ;;
    # RFC 3927 link-local addresses
    169.254.*)
      core::log debug "domain validation failed: RFC 3927 link-local" "$(printf '{"domain":"%s"}' "${domain}")"
      return 1
      ;;
    # RFC 6761 special-use domain names
    *.test | *.invalid)
      core::log debug "domain validation failed: RFC 6761 special-use TLD" "$(printf '{"domain":"%s","rfc":"6761"}' "${domain}")"
      return 1
      ;;
  esac

  # IPv6 private address detection (RFC 4193, RFC 4291)
  # - ::1 (loopback)
  # - fc00::/7 and fd00::/8 (unique local addresses - RFC 4193)
  # - fe80::/10 (link-local - RFC 4291)
  if [[ "${domain}" =~ ^::1$ ]] \
    || [[ "${domain}" =~ ^[fF][cCdD][0-9a-fA-F]{2}: ]] \
    || [[ "${domain}" =~ ^[fF][eE]80: ]]; then
    core::log debug "domain validation failed: IPv6 private/link-local" "$(printf '{"domain":"%s"}' "${domain}")"
    return 1
  fi

  return 0
}

##
# Validate TCP/UDP port number
#
# Validates port number is numeric and within valid range.
#
# Arguments:
#   $1 - Port number (string/number, required)
#
# Returns:
#   0 - Valid port number (1-65535)
#   1 - Invalid port (empty, non-numeric, or out of range)
#
# Example:
#   validators::port "443"     # Valid
#   validators::port "0"       # Invalid (< 1)
#   validators::port "65536"   # Invalid (> 65535)
#   validators::port "abc"     # Invalid (non-numeric)
##
validators::port() {
  local port="${1:-}"

  # Empty check
  if [[ -z "${port}" ]]; then
    core::log debug "port validation failed: empty" "{}"
    return 1
  fi

  # Numeric check
  if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    core::log debug "port validation failed: not numeric" "$(printf '{"port":"%s"}' "${port}")"
    return 1
  fi

  # Range check (1-65535)
  if [[ "${port}" -lt 1 || "${port}" -gt 65535 ]]; then
    core::log debug "port validation failed: out of range" "$(printf '{"port":%s,"valid_range":"1-65535"}' "${port}")"
    return 1
  fi

  return 0
}

##
# Validate UUID (UUIDv4 format)
#
# Validates UUID conforms to standard format: 8-4-4-4-12 hexadecimal digits.
#
# Arguments:
#   $1 - UUID string (string, required)
#
# Returns:
#   0 - Valid UUID format
#   1 - Invalid UUID (empty or malformed)
#
# Example:
#   validators::uuid "550e8400-e29b-41d4-a716-446655440000"  # Valid
#   validators::uuid "invalid-uuid"                           # Invalid
#   validators::uuid "550e8400e29b41d4a716446655440000"       # Invalid (no hyphens)
##
validators::uuid() {
  local uuid="${1:-}"

  # Empty check
  if [[ -z "${uuid}" ]]; then
    core::log debug "uuid validation failed: empty" "{}"
    return 1
  fi

  # UUIDv4 format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  if [[ ! "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    core::log debug "uuid validation failed: invalid format" "$(printf '{"uuid":"%s"}' "${uuid}")"
    return 1
  fi

  return 0
}

##
# Validate shortId for Xray Reality protocol
#
# Validates shortId conforms to Xray Reality protocol requirements.
# Empty strings are valid as they are part of the shortIds pool.
#
# Arguments:
#   $1 - shortId string (string, optional - empty is valid)
#
# Returns:
#   0 - Valid shortId (empty or valid hexadecimal)
#   1 - Invalid shortId (odd length, > 16 chars, or non-hex)
#
# Validation Rules:
#   - Empty string is valid (part of shortIds pool)
#   - Hexadecimal characters only (0-9, a-f, A-F)
#   - Even length required (2, 4, 6, 8, 10, 12, 14, 16)
#   - Maximum 16 characters
#
# Example:
#   validators::shortid ""              # Valid (empty)
#   validators::shortid "a1b2c3d4"      # Valid (8 chars, hex, even)
#   validators::shortid "abc"           # Invalid (odd length)
#   validators::shortid "xyz"           # Invalid (non-hex)
##
validators::shortid() {
  local sid="${1:-}"

  # Empty is valid (part of the pool)
  if [[ -z "${sid}" ]]; then
    return 0
  fi

  # Length check (<= 16)
  if [[ ${#sid} -gt 16 ]]; then
    core::log debug "shortid validation failed: exceeds 16 chars" "$(printf '{"shortid":"%s","length":%d}' "${sid}" ${#sid})"
    return 1
  fi

  # Even length check
  if [[ $((${#sid} % 2)) -ne 0 ]]; then
    core::log debug "shortid validation failed: odd length" "$(printf '{"shortid":"%s","length":%d}' "${sid}" ${#sid})"
    return 1
  fi

  # Hexadecimal check
  if [[ ! "${sid}" =~ ^[0-9a-fA-F]+$ ]]; then
    core::log debug "shortid validation failed: not hexadecimal" "$(printf '{"shortid":"%s"}' "${sid}")"
    return 1
  fi

  return 0
}

##
# Validate TLS fingerprint for Xray/VLESS protocol
#
# Validates fingerprint conforms to supported Xray client fingerprints.
# These fingerprints are used to mimic different browsers/clients.
#
# Arguments:
#   $1 - Fingerprint string (string, required)
#
# Returns:
#   0 - Valid fingerprint
#   1 - Invalid fingerprint (empty or not in supported list)
#
# Supported Fingerprints:
#   - chrome: Google Chrome browser
#   - firefox: Mozilla Firefox browser
#   - safari: Apple Safari browser
#   - ios: iOS devices (iPhone/iPad)
#   - android: Android devices
#   - edge: Microsoft Edge browser
#   - 360: 360 Secure Browser
#   - qq: QQ Browser
#   - random: Random fingerprint (legacy)
#   - randomized: Randomized fingerprint (recommended)
#
# Example:
#   validators::fingerprint "chrome"      # Valid
#   validators::fingerprint "randomized"  # Valid
#   validators::fingerprint "invalid"     # Invalid
##
validators::fingerprint() {
  local fp="${1:-}"

  # Empty check
  if [[ -z "${fp}" ]]; then
    core::log debug "fingerprint validation failed: empty" "{}"
    return 1
  fi

  # Check against supported fingerprints
  case "${fp}" in
    chrome | firefox | safari | ios | android | edge | 360 | qq | random | randomized)
      return 0
      ;;
    *)
      core::log debug "fingerprint validation failed: unsupported" "$(printf '{"fingerprint":"%s","valid":"chrome|firefox|safari|ios|android|edge|360|qq|random|randomized"}' "${fp}")"
      return 1
      ;;
  esac
}

##
# Validate version string
#
# Validates version conforms to semantic versioning or 'latest' keyword.
#
# Arguments:
#   $1 - Version string (string, required)
#
# Returns:
#   0 - Valid version ('latest' or semantic version)
#   1 - Invalid version (empty or malformed)
#
# Accepted Formats:
#   - 'latest' (special keyword)
#   - 'vX.Y.Z' (semantic version with 'v' prefix)
#   - 'X.Y.Z' (semantic version without prefix)
#
# Example:
#   validators::version "latest"    # Valid
#   validators::version "v1.8.7"    # Valid
#   validators::version "1.8.7"     # Valid
#   validators::version "v1.8"      # Invalid (incomplete)
#   validators::version "abc"       # Invalid
##
validators::version() {
  local version="${1:-}"

  # Empty check
  if [[ -z "${version}" ]]; then
    core::log debug "version validation failed: empty" "{}"
    return 1
  fi

  # Accept 'latest'
  if [[ "${version}" == "latest" ]]; then
    return 0
  fi

  # Semantic version format: vX.Y.Z or X.Y.Z
  if [[ ! "${version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    core::log debug "version validation failed: invalid format" "$(printf '{"version":"%s","expected":"vX.Y.Z or latest"}' "${version}")"
    return 1
  fi

  return 0
}
