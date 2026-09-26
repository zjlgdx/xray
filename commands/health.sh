#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "${HERE}/lib/core.sh"
. "${HERE}/lib/health_check.sh"

usage() {
  cat << 'EOF'
Usage: xrf health [options]

Run comprehensive health check on Xray installation.

Options:
  --json                        Output in JSON format
  --help, -h                    Show this help

Checks performed:
  - Service Status    (systemd unit status)
  - Configuration     (xray config validation)
  - Network           (port listening checks)
  - Compatibility     (deprecated setting warnings)

Examples:
  # Run health check
  xrf health

  # JSON output
  xrf health --json

Exit codes:
  0 - All checks passed
  1 - One or more checks failed

EOF
}

main() {
  core::init "${@}"

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --json)
        export XRF_JSON="true"
        shift
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        core::log error "unknown option" "$(printf '{"option":"%s"}' "${1}")"
        usage
        exit 1
        ;;
    esac
  done

  # Run health check
  if health::run; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
