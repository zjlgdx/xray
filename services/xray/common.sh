#!/usr/bin/env bash
# Common Xray paths and utilities
# NOTE: This file is sourced. Strict mode is set by core::init() from the calling script

# Source guard: prevent double-sourcing
[[ -n "${_XRF_XRAY_COMMON_LOADED:-}" ]] && return 0
readonly _XRF_XRAY_COMMON_LOADED=1

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
. "${HERE}/lib/core.sh"

xray::prefix() { echo "${XRF_PREFIX:-/usr/local}"; }
xray::etc() { echo "${XRF_ETC:-/usr/local/etc}"; }
xray::confbase() { echo "$(xray::etc)/xray"; }
xray::releases() { echo "$(xray::confbase)/releases"; }
xray::active() { echo "$(xray::confbase)/active"; }
xray::bin() { echo "$(xray::prefix)/bin/xray"; }

##
# Parse semantic version from xray command output.
#
# Arguments:
#   $1 - Raw command output (string, required)
#
# Output:
#   Normalized version string (vX.Y.Z) or empty string
#
# Returns:
#   0 - Always succeeds
##
xray::parse_version_text() {
  local raw="${1:-}" token
  [[ -z "${raw}" ]] && return 0

  token="$(
    printf '%s\n' "${raw}" | awk '
      NR == 1 {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) { print substr($i, 2); exit }
          if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
        }
      }
    '
  )"
  [[ -n "${token}" ]] || return 0

  printf 'v%s' "${token}"
  return 0
}

##
# Detect installed xray binary version.
#
# Tries "-version" then falls back to "version" for compatibility across builds.
#
# Arguments:
#   $1 - Optional xray binary path (string, optional, default: xray::bin)
#
# Output:
#   Version string (vX.Y.Z) or "unknown"
#
# Returns:
#   0 - Always succeeds
##
xray::installed_version() {
  local xray_bin="${1:-$(xray::bin)}"
  local raw="" version=""

  [[ -x "${xray_bin}" ]] || {
    printf 'unknown'
    return 0
  }

  raw="$("${xray_bin}" -version 2> /dev/null || true)"
  version="$(xray::parse_version_text "${raw}")"
  if [[ -z "${version}" ]]; then
    raw="$("${xray_bin}" version 2> /dev/null || true)"
    version="$(xray::parse_version_text "${raw}")"
  fi

  printf '%s' "${version:-unknown}"
  return 0
}

##
# Extract compatibility warnings from Xray output or config text.
#
# Arguments:
#   $1 - Source text to inspect (string, required)
#
# Output:
#   Zero or more warning lines
#
# Returns:
#   0 - Always succeeds
##
xray::extract_compat_warnings() {
  local text="${1:-}" lower
  [[ -z "${text}" ]] && return 0

  lower="$(printf '%s' "${text}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${lower}" == *"allowinsecure"* ]]; then
    printf '%s\n' 'deprecated TLS option allowInsecure detected; migrate to pinnedPeerCertSha256 + verifyPeerCertByName'
  fi
  if [[ "${lower}" == *"verifypeercertinnames"* || "${lower}" == *"servernametoverify"* ]]; then
    printf '%s\n' 'deprecated TLS option verifyPeerCertInNames or serverNameToVerify detected; use verifyPeerCertByName'
  fi
  if [[ "${lower}" == *"deprecated"* && "${lower}" != *"allowinsecure"* && "${lower}" != *"verifypeercertinnames"* && "${lower}" != *"servernametoverify"* ]]; then
    printf '%s\n' 'Xray reported generic deprecation warnings; inspect xray -test output for migration guidance'
  fi

  # v26.3.27+: REALITY non-443 port warning
  if [[ "${lower}" == *"reality"* && "${lower}" == *"443"* ]] \
    && [[ "${lower}" == *"warn"* || "${lower}" == *"not 443"* || "${lower}" == *"non-443"* ]]; then
    printf '%s\n' 'Xray warns: REALITY on non-443 port may reduce stealth; port 443 is recommended'
  fi

  # v26.3.27+: Apple/iCloud destination warning
  if [[ "${lower}" == *"apple"* || "${lower}" == *"icloud"* ]] \
    && [[ "${lower}" == *"block"* || "${lower}" == *"warn"* || "${lower}" == *"risk"* ]]; then
    printf '%s\n' 'Xray warns: Apple/iCloud REALITY destinations may cause IP blocking; choose a different target'
  fi
}

##
# Generate a random shortId for Xray Reality
#
# Creates a 16-character hexadecimal string using reliable tools.
# Tries xxd → od → openssl (in order of preference).
#
# Output:
#   16-character hexadecimal string to stdout
#
# Returns:
#   0 - Success
#   1 - All tools failed (should never happen, openssl is always available)
#
# Example:
#   shortid=$(xray::generate_shortid)
#   # Output: a1b2c3d4e5f67890
##
xray::generate_shortid() {
  local result=""

  if command -v xxd > /dev/null 2>&1; then
    result="$(head -c 8 /dev/urandom | xxd -p -c 16)"
  elif command -v od > /dev/null 2>&1; then
    result="$(head -c 8 /dev/urandom | od -An -tx1 -v | tr -d ' \n')"
  elif command -v openssl > /dev/null 2>&1; then
    result="$(openssl rand -hex 8)"
  else
    # This should never happen as openssl is a project dependency
    core::log error "no suitable tool found for shortId generation" "{}"
    return 1
  fi

  # Output the result
  echo "${result}"
  return 0
}
