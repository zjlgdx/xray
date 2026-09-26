#!/usr/bin/env bash
# Installation preview and confirmation

# Source guard: prevent double-sourcing (readonly variables cannot be re-declared)
[[ -n "${_XRF_PREVIEW_LOADED:-}" ]] && return 0
readonly _XRF_PREVIEW_LOADED=1

# Load defaults (needed for port defaults)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/defaults.sh
. "${HERE}/lib/defaults.sh"

##
# Display installation configuration preview
#
# Shows a comprehensive summary of the installation configuration
# before proceeding with actual installation. Supports both text
# and JSON output formats.
#
# Arguments:
#   None (reads from environment variables)
#
# Globals:
#   VERSION - Xray version
#   XRAY_PORT - REALITY port
#   XRF_JSON - If "true", output JSON format
#
# Output:
#   Configuration preview to stdout (text or JSON format)
#
# Returns:
#   0 - Always succeeds
#
# Example:
#   preview::show
##
preview::show() {
  # shellcheck disable=SC2154  # Set by args::parse/core::init in the caller.
  local version="${VERSION}"
  local port="${XRAY_PORT:-${DEFAULT_XRAY_PORT}}"
  local sni="${XRAY_SNI:-}" target
  target="${XRAY_REALITY_DEST:-${sni%%,*}:443}"
  [[ "${target}" == *:* ]] || target="${target}:443"
  # shellcheck disable=SC2154
  if [[ "${XRF_JSON}" == "true" ]]; then
    jq -n --arg version "${version}" --argjson port "${port}" --arg sni "${sni}" --arg target "${target}" \
      '{preview:{topology:"reality-only",version:$version,port:$port,sni:$sni,target:$target}}'
  else
    printf '\nInstallation Preview\n  Topology: reality-only\n  Xray: %s\n  Port: %s (REALITY)\n  SNI: %s\n  Target: %s\n\n' "${version}" "${port}" "${sni}" "${target}"
  fi
}

##
# Prompt user for installation confirmation
#
# Displays a confirmation prompt and waits for user input.
# Supports automatic confirmation via --yes flag or non-interactive mode.
#
# Arguments:
#   None
#
# Globals:
#   XRF_YES - If "true", auto-confirm without prompt
#   XRF_JSON - If "true", skip prompt (non-interactive)
#
# Input:
#   User response from stdin (Y/n)
#
# Output:
#   Confirmation prompt to stderr (interactive mode only)
#
# Returns:
#   0 - User confirmed (or auto-confirmed)
#   1 - User declined
#
# Example:
#   preview::confirm || exit 1
##
preview::confirm() {
  # Auto-confirm in non-interactive modes
  # shellcheck disable=SC2154  # XRF_YES and XRF_JSON are set by core::init or args
  if [[ "${XRF_YES:-false}" == "true" ]] || [[ "${XRF_JSON}" == "true" ]]; then
    return 0
  fi

  # Check if running in non-interactive environment
  if [[ ! -t 0 ]]; then
    # stdin is not a terminal (e.g., piped input)
    core::log info "non-interactive mode detected, auto-confirming" "{}"
    return 0
  fi

  # Interactive prompt
  local response=""
  printf "Proceed with installation? [Y/n] " >&2
  read -r response

  # Default to Yes if empty
  response="${response:-Y}"

  case "${response}" in
    [Yy] | [Yy][Ee][Ss])
      return 0
      ;;
    *)
      core::log info "installation cancelled by user" "{}"
      return 1
      ;;
  esac
}

##
# Check if running in dry-run mode
#
# Returns success if --dry-run flag is set, indicating that
# the installation should only show preview without executing.
#
# Arguments:
#   None
#
# Globals:
#   XRF_DRY_RUN - If "true", running in dry-run mode
#
# Returns:
#   0 - Dry-run mode enabled
#   1 - Normal mode
#
# Example:
#   if preview::is_dry_run; then
#     core::log info "dry-run mode, skipping installation" "{}"
#     exit 0
#   fi
##
preview::is_dry_run() {
  [[ "${XRF_DRY_RUN:-false}" == "true" ]]
}
