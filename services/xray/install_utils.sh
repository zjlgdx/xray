#!/usr/bin/env bash
# Xray installation utilities
# NOTE: This file is sourced. Strict mode is set by core::init() from the calling script

# Source guard: prevent double-sourcing
[[ -n "${_XRF_INSTALL_UTILS_LOADED:-}" ]] && return 0
readonly _XRF_INSTALL_UTILS_LOADED=1

##
# Extract SHA256 hash from .dgst file content
#
# Handles multiple .dgst file formats commonly used by Xray-core releases:
# - Format 1 (labeled): SHA256 (Xray-linux-64.zip) = abc123...
# - Format 2 (labeled, compact): SHA256(file)=hash
# - Format 3 (plain): abc123... Xray-linux-64.zip
# - Format 4 (plain, line-start): abc123...
#
# Priority: Labeled SHA256 formats first to avoid extracting SHA512's first 64 chars.
#
# Arguments:
#   $1 - Content of .dgst file (string, required)
#
# Output:
#   SHA256 hash (64 hex chars) to stdout, or empty string if not found
#
# Returns:
#   0 - Always succeeds (returns empty string if hash not found)
#
# Security:
#   Prevents CWE-345 (Insufficient Verification of Data Authenticity) by:
#   - Prioritizing labeled SHA256 format over plain hash format
#   - Avoiding extraction of SHA512 hash when both present
#
# Example:
#   dgst_content="$(curl -fsSL "${url}.dgst")"
#   sha="$(xray::extract_sha256_from_dgst "${dgst_content}")"
##
xray::extract_sha256_from_dgst() {
  local dgst_content="${1}"
  local sha=""

  [[ -z "${dgst_content}" ]] && return 0

  # Priority 1: Try labeled SHA256 format first (most reliable)
  # Matches: "SHA256 (file) = hash", "SHA256(file)=hash", or "SHA2-256= hash"
  sha="$(echo "${dgst_content}" | grep -iE 'SHA2?-?256' | grep -oE '[0-9A-Fa-f]{64}' | head -1)" || true

  # Priority 2: Fallback to plain hash at line start
  # Matches: "hash  filename" (two spaces separator)
  if [[ -z "${sha}" ]]; then
    sha="$(echo "${dgst_content}" | grep -oE '^[0-9A-Fa-f]{64}' | head -1)" || true
  fi

  echo "${sha}"
  return 0
}

##
# Validate SHA256 hash format
#
# Checks if a string is a valid 64-character hexadecimal SHA256 hash.
#
# Arguments:
#   $1 - SHA256 hash to validate (string, required)
#
# Returns:
#   0 - Valid SHA256 format
#   1 - Invalid format (not 64 hex chars)
#
# Example:
#   if xray::validate_sha256_format "${sha}"; then
#     echo "Valid SHA256"
#   fi
##
xray::validate_sha256_format() {
  local sha="${1}"
  [[ "${sha}" =~ ^[0-9A-Fa-f]{64}$ ]]
}

##
# Verify file checksum against expected SHA256
#
# Computes the SHA256 checksum of a file and compares it to the expected value.
# Uses sha256sum (coreutils) for computation.
#
# Arguments:
#   $1 - File path (string, required)
#   $2 - Expected SHA256 hash (string, required, 64 hex chars)
#
# Globals:
#   Uses core::log if available for structured logging
#
# Returns:
#   0 - Checksum matches
#   1 - Checksum mismatch or file not readable
#
# Example:
#   if xray::verify_file_checksum "${file}" "${expected_sha}"; then
#     echo "Checksum verified"
#   fi
##
xray::verify_file_checksum() {
  local file="${1}"
  local expected_sha="${2}"

  [[ -r "${file}" ]] || return 1

  local got
  got="$(sha256sum "${file}" | awk '{print $1}')" || return 1

  if [[ "${got}" != "${expected_sha}" ]]; then
    if declare -f core::log > /dev/null 2>&1; then
      core::log error "SHA256 mismatch" "$(printf '{"expected":"%s","got":"%s","file":"%s"}' "${expected_sha}" "${got}" "${file}")"
    fi
    return 1
  fi

  return 0
}

##
# Select the most recently published non-draft release from GitHub's release list.
#
# Arguments:
#   $1 - JSON payload content (string, required)
#
# Output:
#   Release tag (vX.Y.Z)
#
# Returns:
#   0 - A published release with a canonical tag was found
#   1 - Invalid response or no usable release
##
xray::extract_latest_tag_from_release_json() {
  local payload="${1:-}"
  [[ -n "${payload}" ]] || return 1
  printf '%s' "${payload}" | jq -er '
    if type != "array" then empty else
      [ .[]
        | if .draft == true then empty
          elif .draft == false then
            {tag: .tag_name, published: (.published_at | fromdateiso8601)}
          else error("invalid release draft field") end
      ]
      | if length == 0 then empty else max_by(.published).tag end
      | if type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")
        then . else error("invalid newest release tag") end
    end
  ' 2> /dev/null
}

##
# Resolve the most recently published non-draft release, including prereleases.
#
# Arguments:
#   $1 - Optional releases API base URL (string, optional)
#
# Output:
#   Release tag (vX.Y.Z)
#
# Returns:
#   0 - Success
#   1 - Failed to fetch/parse latest tag
##
xray::resolve_latest_tag() {
  local api_url="${1:-https://api.github.com/repos/XTLS/Xray-core/releases}"
  local payload previous_page="" tag count page=1
  local pages=()

  command -v jq > /dev/null 2>&1 || return 1

  # GitHub paginates at 100 releases. Search every page because a release
  # published today may have been created before the first page's releases.
  while ((page <= 100)); do
    if declare -f core::retry > /dev/null 2>&1; then
      payload="$(core::retry 3 curl -fsSL "${api_url}?per_page=100&page=${page}" 2> /dev/null)" || return 1
    else
      payload="$(curl -fsSL "${api_url}?per_page=100&page=${page}" 2> /dev/null)" || return 1
    fi
    [[ "${page}" -eq 1 || "${payload}" != "${previous_page}" ]] || return 1
    count="$(printf '%s' "${payload}" | jq -e 'if type == "array" then length else error("expected release list") end' 2> /dev/null)" || return 1
    pages+=("${payload}")
    ((count < 100)) && break
    previous_page="${payload}"
    page=$((page + 1))
  done
  ((page <= 100)) || return 1

  payload="$(printf '%s\n' "${pages[@]}" | jq -s 'add')" || return 1
  tag="$(xray::extract_latest_tag_from_release_json "${payload}")" || return 1
  printf '%s' "${tag}"
  return 0
}
