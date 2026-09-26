#!/usr/bin/env bash
# Unified argument parsing module for xray-fusion
# Provides consistent parameter interface for both install.sh and xrf commands
# NOTE: This file is sourced. Strict mode is set by the calling script or core::init()

# Source guard: prevent double-sourcing
[[ -n "${_XRF_ARGS_LOADED:-}" ]] && return 0
readonly _XRF_ARGS_LOADED=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/defaults.sh
. "${HERE}/lib/defaults.sh"
# shellcheck source=lib/validators.sh
. "${HERE}/lib/validators.sh"

# Initialize default values
args::init() {
  VERSION="${DEFAULT_VERSION}"
  DEBUG="${DEFAULT_XRF_DEBUG}"
  UUID=""
  UUID_FROM_STRING=""
  XRF_YES="false"
  XRF_DRY_RUN="false"
  FINGERPRINT="${DEFAULT_XRAY_FINGERPRINT}"
}

# Parse command line arguments
args::parse() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --fingerprint | -f)
        args::validate_fingerprint "${2:-}" || return 1
        FINGERPRINT="${2}"
        shift 2
        ;;
      --version | -v)
        args::validate_version "${2:-}" || return 1
        VERSION="${2}"
        shift 2
        ;;
      --uuid)
        UUID="${2:-}"
        shift 2
        ;;
      --uuid-from-string)
        UUID_FROM_STRING="${2:-}"
        shift 2
        ;;
      --debug)
        DEBUG="true"
        shift
        ;;
      --yes | -y)
        XRF_YES="true"
        shift
        ;;
      --dry-run)
        XRF_DRY_RUN="true"
        shift
        ;;
      --help | -h)
        return 10 # Special return code for help
        ;;
      --)
        shift
        break
        ;;
      *)
        core::log error "unknown argument" "$(printf '{"arg":"%s"}' "${1}")"
        return 1
        ;;
    esac
  done

  # Validate configuration
  # Validate UUID parameters if provided
  if [[ -n "${UUID}" && -n "${UUID_FROM_STRING}" ]]; then
    core::log error "cannot use both --uuid and --uuid-from-string" "{}"
    return 1
  fi

  # Export variables for use by other modules
  export VERSION DEBUG UUID UUID_FROM_STRING XRF_YES XRF_DRY_RUN FINGERPRINT

  return 0
}

# Version validation
args::validate_version() {
  local version="${1:-}"
  if [[ -z "${version}" ]]; then
    core::log error "version cannot be empty" "{}"
    return 1
  fi

  # Use shared validator (accepts 'latest' or vX.Y.Z)
  if ! validators::version "${version}"; then
    core::log error "invalid version format" "$(printf '{"version":"%s","format":"vX.Y.Z or latest"}' "${version}")"
    return 1
  fi

  return 0
}

# Fingerprint validation
args::validate_fingerprint() {
  local fingerprint="${1:-}"
  if [[ -z "${fingerprint}" ]]; then
    core::log error "fingerprint cannot be empty" "{}"
    return 1
  fi

  # Use shared validator (accepts chrome/firefox/safari/ios/android/edge/360/qq/random/randomized)
  if ! validators::fingerprint "${fingerprint}"; then
    core::log error "invalid fingerprint" "$(printf '{"fingerprint":"%s","valid":"chrome|firefox|safari|ios|android|edge|360|qq|random|randomized"}' "${fingerprint}")"
    return 1
  fi

  return 0
}

# Show help for common arguments
args::show_help() {
  cat << EOF
Options:
  --fingerprint, -f <type>      TLS fingerprint (default: chrome)
                                Valid: chrome, firefox, safari, ios, android, edge, 360, qq, random, randomized
  --version, -v <version>       Xray version to install (default: latest)
  --uuid <uuid>                 Custom UUID (default: auto-generated)
  --uuid-from-string <string>   Generate UUID from custom string
  --yes, -y                     Auto-confirm installation (skip prompt)
  --dry-run                     Show preview without installing
  --debug                       Enable debug output
  --help, -h                    Show this help

Examples:
  # Preview without installing
  --dry-run

  # Auto-confirm installation
  --yes

  # Specific version
  --version v1.8.1

EOF
}

# Export parsed arguments as environment variables
args::export_vars() {
  # Set XRAY_FINGERPRINT for client link generation
  if [[ -n "${FINGERPRINT}" ]]; then
    export XRAY_FINGERPRINT="${FINGERPRINT}"
  fi

  # Set XRF_DEBUG for core module
  export XRF_DEBUG="${DEBUG}"
}
