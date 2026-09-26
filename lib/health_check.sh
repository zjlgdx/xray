#!/usr/bin/env bash
# Health check system for post-installation validation

# Source guard: prevent double-sourcing (readonly variables cannot be re-declared)
[[ -n "${_XRF_HEALTH_CHECK_LOADED:-}" ]] && return 0
readonly _XRF_HEALTH_CHECK_LOADED=1

# Load required modules
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=modules/state.sh
. "${HERE}/modules/state.sh"
# shellcheck source=services/xray/common.sh
. "${HERE}/services/xray/common.sh"

##
# Check if Xray systemd service is running
#
# Uses systemctl to check service status. Returns success if service
# is active (running), failure otherwise.
#
# Arguments:
#   None
#
# Output:
#   Service status info to stderr (via core::log)
#
# Returns:
#   0 - Service is active (running)
#   1 - Service is not running or not found
#
# Example:
#   health::check_service
##
health::check_service() {
  core::log debug "checking xray service status" "{}"

  # Check if systemctl is available
  if ! command -v systemctl > /dev/null 2>&1; then
    core::log warn "systemctl not found, skipping service check" "{}"
    return 1
  fi

  # Check service status
  if systemctl is-active --quiet xray.service 2> /dev/null; then
    core::log debug "xray service is active" "{}"
    return 0
  else
    core::log warn "xray service is not active" "{}"
    return 1
  fi
}

##
# Validate Xray configuration file
#
# Uses xray -test to validate configuration syntax and semantics.
# Returns success if configuration is valid, failure otherwise.
#
# Arguments:
#   None
#
# Globals:
#   Uses xray::bin() to get xray binary path
#   Uses xray::confbase() to get config directory
#
# Output:
#   Configuration validation info to stderr (via core::log)
#
# Returns:
#   0 - Configuration is valid
#   1 - Configuration is invalid or xray not found
#
# Example:
#   health::check_config
##
health::check_config() {
  core::log debug "validating xray configuration" "{}"

  local xray_bin
  xray_bin="$(xray::bin)"

  # Check if xray binary exists
  if [[ ! -x "${xray_bin}" ]]; then
    core::log warn "xray binary not found" "$(printf '{"path":"%s"}' "${xray_bin}")"
    return 1
  fi

  local config_dir
  config_dir="$(xray::active)"

  # Check if active config directory exists
  if [[ ! -d "${config_dir}" ]]; then
    core::log warn "xray active config directory not found" "$(printf '{"path":"%s"}' "${config_dir}")"
    return 1
  fi

  # Ensure the directory contains JSON config files before running validation
  if ! compgen -G "${config_dir}"'/*.json' > /dev/null; then
    core::log warn "xray config files missing" "$(printf '{"path":"%s"}' "${config_dir}")"
    return 1
  fi

  # Run configuration test
  # xray -test returns 0 if config is valid
  local test_output
  if test_output="$("${xray_bin}" -test -confdir "${config_dir}" 2>&1)"; then
    local compat_warning
    while IFS= read -r compat_warning; do
      [[ -n "${compat_warning}" ]] || continue
      core::log warn "${compat_warning}" "$(printf '{"source":"xray-test"}')"
    done < <(xray::extract_compat_warnings "${test_output}")
    core::log debug "xray configuration is valid" "{}"
    return 0
  else
    core::log warn "xray configuration is invalid" "{}"
    [[ -n "${test_output}" ]] && printf '%s\n' "${test_output}" >&2
    return 1
  fi
}

##
# Check if network ports are listening
#
# Uses netstat or ss to check if configured ports are listening.
# Checks ports based on installed topology (from state.json).
#
# Arguments:
#   None
#
# Globals:
#   Reads state.json via state::load
#
# Output:
#   Port listening status to stderr (via core::log)
#
# Returns:
#   0 - All required ports are listening
#   1 - One or more ports are not listening or check failed
#
# Example:
#   health::check_network
##
health::check_network() {
  core::log debug "checking network ports" "{}"

  # Load state to get topology and ports
  local state
  state="$(state::load)"

  if [[ -z "${state}" || "${state}" == "{}" ]]; then
    core::log warn "no state found, skipping network check" "{}"
    return 1
  fi

  local port
  if ! port="$(printf '%s\n' "${state}" | jq -er 'select(.name == "reality-only") | .xray.port')" \
    || [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    core::log warn "managed REALITY listener port missing" '{}'
    return 1
  fi

  # Check whether the managed REALITY port is listening.
  # Try ss first (modern), fall back to netstat
  local check_cmd=""
  if command -v ss > /dev/null 2>&1; then
    check_cmd="ss"
  elif command -v netstat > /dev/null 2>&1; then
    check_cmd="netstat"
  else
    core::log warn "neither ss nor netstat found, skipping network check" "{}"
    return 1
  fi

  if [[ "${check_cmd}" == "ss" ]]; then
    ss -tuln | grep -q ":${port} " && return 0
  else
    netstat -tuln | grep -q ":${port} " && return 0
  fi
  core::log warn "port is not listening" "$(printf '{"port":%d}' "${port}")"
  return 1
}

##
# Check configuration compatibility against known Xray deprecations.
#
# Scans rendered JSON files for known deprecated fields and emits warning
# messages. This check is informational and should not block installation.
#
# Returns:
#   0 - No known deprecated settings detected
#   1 - One or more compatibility warnings detected (informational)
##
health::check_compatibility() {
  core::log debug "checking compatibility warnings" "{}"

  local config_dir
  config_dir="$(xray::active)"
  if [[ ! -d "${config_dir}" ]]; then
    core::log warn "xray active config directory not found for compatibility check" "$(printf '{"path":"%s"}' "${config_dir}")"
    return 1
  fi

  if ! compgen -G "${config_dir}"'/*.json' > /dev/null; then
    core::log warn "xray config files missing for compatibility check" "$(printf '{"path":"%s"}' "${config_dir}")"
    return 1
  fi

  local combined warnings
  combined="$(cat "${config_dir}"/*.json 2> /dev/null || true)"
  warnings="$(xray::extract_compat_warnings "${combined}")"
  if [[ -z "${warnings}" ]]; then
    return 0
  fi

  printf '%s\n' "${warnings}"
  return 1
}

##
# Run comprehensive health check
#
# Runs all health checks and returns overall status.
# Supports both text and JSON output formats.
#
# Arguments:
#   None
#
# Globals:
#   XRF_JSON - If "true", output JSON format
#
# Output:
#   Health check report to stdout (text or JSON format)
#
# Returns:
#   0 - All checks passed
#   1 - One or more checks failed
#
# Example:
#   health::run
##
health::run() {
  core::log info "running health checks" "{}"

  # Run all checks
  local service_ok=0
  local config_ok=0
  local network_ok=0
  local compat_ok=0
  local compat_output=""

  health::check_service && service_ok=1 || service_ok=0
  health::check_config && config_ok=1 || config_ok=0
  health::check_network && network_ok=1 || network_ok=0
  if compat_output="$(health::check_compatibility)"; then
    compat_ok=1
  else
    compat_ok=0
  fi

  # Calculate overall status
  local all_passed=0
  if [[ "${service_ok}" -eq 1 && "${config_ok}" -eq 1 && "${network_ok}" -eq 1 ]]; then
    all_passed=1
  fi

  # Get detailed status messages
  local service_msg config_msg network_msg compat_msg
  if [[ "${service_ok}" -eq 1 ]]; then
    service_msg="xray.service is active (running)"
  else
    service_msg="xray.service is not running"
  fi

  if [[ "${config_ok}" -eq 1 ]]; then
    config_msg="Valid Xray configuration"
  else
    config_msg="Invalid or missing configuration"
  fi

  if [[ "${network_ok}" -eq 1 ]]; then
    network_msg="All required ports listening"
  else
    network_msg="Some ports not listening"
  fi

  if [[ "${compat_ok}" -eq 1 ]]; then
    compat_msg="No known deprecated settings detected"
  else
    compat_msg="${compat_output:-Compatibility warnings detected; inspect logs}"
  fi

  # shellcheck disable=SC2154  # XRF_JSON is set by core::init
  if [[ "${XRF_JSON}" == "true" ]]; then
    # JSON format
    local json_output
    json_output=$(
      cat << EOF
{
  "health": {
    "service": {"passed": $([ "${service_ok}" -eq 1 ] && echo "true" || echo "false"), "message": "${service_msg}"},
    "config": {"passed": $([ "${config_ok}" -eq 1 ] && echo "true" || echo "false"), "message": "${config_msg}"},
    "network": {"passed": $([ "${network_ok}" -eq 1 ] && echo "true" || echo "false"), "message": "${network_msg}"},
    "compatibility": {"passed": $([ "${compat_ok}" -eq 1 ] && echo "true" || echo "false"), "message": "${compat_msg}"}
  },
  "overall": $([ "${all_passed}" -eq 1 ] && echo "true" || echo "false")
}
EOF
    )
    printf '%s\n' "${json_output}"
  else
    # Text format
    printf '\nHealth Check Report\n\n'
    printf '  %s Service Status    %s\n' "$([ "${service_ok}" -eq 1 ] && echo "✓" || echo "✗")" "${service_msg}"
    printf '  %s Configuration     %s\n' "$([ "${config_ok}" -eq 1 ] && echo "✓" || echo "✗")" "${config_msg}"
    printf '  %s Network           %s\n' "$([ "${network_ok}" -eq 1 ] && echo "✓" || echo "✗")" "${network_msg}"
    printf '  %s Compatibility     %s\n' "$([ "${compat_ok}" -eq 1 ] && echo "✓" || echo "!")" "${compat_msg}"
    printf '\n'

    if [[ "${all_passed}" -eq 1 ]]; then
      printf 'Overall: Healthy ✓\n\n'
    else
      printf 'Overall: Issues detected ✗\n\n'
    fi
  fi

  # Return overall status
  [[ "${all_passed}" -eq 1 ]]
}
