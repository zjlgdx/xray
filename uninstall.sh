#!/usr/bin/env bash
# xray-fusion online uninstaller
# Usage: curl -sL https://raw.githubusercontent.com/zjlgdx/xray/main/uninstall.sh | bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
INSTALL_DIR="${XRF_INSTALL_DIR:-/usr/local/xray-fusion}"

# Runtime variables
FORCE=""
DEBUG=""
REMOVE_INSTALL_DIR=""

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} ${*}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} ${*}"; }
log_error() { echo -e "${RED}[ERROR]${NC} ${*}"; }
log_debug() { [[ "${DEBUG}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${*}" || true; }

# Removed abort_non_interactive function as it's no longer needed

# Error handling
error_exit() {
  log_error "${1}"
  exit 1
}

# Show help
show_help() {
  cat << EOF
xray-fusion online uninstaller

Usage:
  curl -sL https://raw.githubusercontent.com/zjlgdx/xray/main/uninstall.sh | bash
  curl -sL https://raw.githubusercontent.com/zjlgdx/xray/main/uninstall.sh | bash -s -- [options]

Options:
  --remove-install-dir          Remove the entire installation directory
  --force                       Force uninstallation without confirmation
  --debug                       Enable debug output
  --help                        Show this help

Examples:
  # Complete uninstallation
  curl -sL https://raw.githubusercontent.com/zjlgdx/xray/main/uninstall.sh | bash

  # Force uninstallation without confirmation
  curl -sL https://raw.githubusercontent.com/zjlgdx/xray/main/uninstall.sh | bash -s -- --force

Environment Variables:
  XRF_INSTALL_DIR   Installation directory (default: /usr/local/xray-fusion)

EOF
}

# Check if xray-fusion is installed
check_installation() {
  log_info "Checking xray-fusion installation status..."

  # Check if xrf command exists or installation directory exists
  if ! command -v xrf > /dev/null 2>&1 && [[ ! -d "${INSTALL_DIR}" ]]; then
    log_warn "xray-fusion not installed or not found at expected location"
    if [[ "${FORCE}" != "true" ]]; then
      # Improved non-interactive detection
      if [[ -t 0 && -t 1 ]]; then
        read -p "Still want to continue uninstallation? [y/N]: " -r
        if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
          log_info "Uninstallation cancelled"
          exit 0
        fi
      else
        log_warn "Non-interactive mode detected, use --force parameter to force uninstallation"
        return 1
      fi
    fi
  fi

  log_info "Found xray-fusion installation"
  return 0
}

# Get installation info
get_installation_info() {
  log_info "Gathering installation information..."

  # Try to get status from installed xrf
  if command -v xrf > /dev/null 2>&1; then
    log_debug "Getting status from installed xrf..."
    if xrf status 2> /dev/null; then
      echo ""
    fi
  fi

  # Check systemd service
  if systemctl is-active --quiet xray 2> /dev/null; then
    log_info "Xray service is currently running"
  elif systemctl is-enabled --quiet xray 2> /dev/null; then
    log_info "Xray service is enabled but not running"
  fi

  # Show what will be removed
  echo ""
  log_info "The following will be removed:"
  [[ -L /usr/local/bin/xrf ]] && echo "  - Global xrf command: /usr/local/bin/xrf"
  [[ -d "${INSTALL_DIR}" ]] && echo "  - Installation directory: ${INSTALL_DIR}"

  # Check for Xray binaries and configs
  local xray_locations=(
    "/usr/local/bin/xray"
    "/usr/local/etc/xray"
    "/etc/systemd/system/xray.service"
  )

  for location in "${xray_locations[@]}"; do
    if [[ -e "${location}" ]]; then
      echo "  - ${location}"
    fi
  done
  echo ""
}

# Confirm uninstallation
confirm_uninstallation() {
  if [[ "${FORCE}" == "true" ]]; then
    log_info "Force mode enabled, skipping confirmation"
    return 0
  fi

  log_warn "This will completely remove xray-fusion and Xray from your system!"

  # Improved interactive check
  if [[ -t 0 && -t 1 ]]; then
    read -p "Are you sure you want to continue? [y/N]: " -r
    if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
      log_info "Uninstallation cancelled"
      exit 0
    fi
  else
    log_info "Non-interactive mode detected, continuing with uninstallation..."
  fi
}

# Uninstall through the installed command so its shared lock protects state/config.
run_xrf_uninstall() {
  if [[ ! -x "${INSTALL_DIR}/bin/xrf" ]]; then
    log_error "Installed xrf command is unavailable: ${INSTALL_DIR}/bin/xrf"
    return 1
  fi
  log_info "Running xray-fusion uninstall..."
  "${INSTALL_DIR}/bin/xrf" uninstall || return 1
  log_info "xray-fusion uninstall completed"
}

# Clean up symlinks
cleanup_symlinks() {
  local link_path="${1:-/usr/local/bin/xrf}"
  if [[ -L "${link_path}" && "$(readlink "${link_path}")" == "${INSTALL_DIR}/bin/xrf" ]]; then
    rm -f "${link_path}" || return 1
    log_debug "Removed own symlink: ${link_path}"
  fi
  return 0
}

# Remove installation directory
remove_installation_directory() {
  if [[ "${REMOVE_INSTALL_DIR}" == "true" && -d "${INSTALL_DIR}" ]]; then
    log_info "Removing installation directory: ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
  elif [[ -d "${INSTALL_DIR}" ]]; then
    log_info "Installation directory preserved: ${INSTALL_DIR}"
    log_info "To remove it manually: rm -rf ${INSTALL_DIR}"
  fi
}

# Show uninstallation summary
show_summary() {
  echo ""
  log_info "Uninstallation Summary:"
  echo "  ✓ Systemd service removed"
  echo "  ✓ Xray binary removed"
  echo "  ✓ Configuration files removed"
  echo "  ✓ Owned global xrf link removed if present"
  [[ "${REMOVE_INSTALL_DIR}" == "true" ]] && echo "  ✓ Installation directory removed" || echo "  ✓ Installation directory preserved"
  echo ""
  log_info "xray-fusion has been successfully uninstalled!"

  if [[ "${REMOVE_INSTALL_DIR}" != "true" && -d "${INSTALL_DIR}" ]]; then
    echo ""
    log_info "Installation directory was preserved: ${INSTALL_DIR}"
    echo "  To remove: sudo rm -rf ${INSTALL_DIR}"
  fi
}

# Parse command line arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case ${1} in
      --remove-install-dir)
        REMOVE_INSTALL_DIR="true"
        shift
        ;;
      --force)
        FORCE="true"
        shift
        ;;
      --debug)
        DEBUG="true"
        shift
        ;;
      --help | -h)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown option: ${1}"
        return 2
        ;;
    esac
  done
}

# Main function
main() {
  parse_args "${@}" || return $?
  echo -e "${RED}"
  cat << 'EOF'
 ██╗  ██╗██████╗  █████╗ ██╗   ██╗      ███████╗██╗   ██╗███████╗██╗ ██████╗ ███╗   ██╗
 ╚██╗██╔╝██╔══██╗██╔══██╗╚██╗ ██╔╝      ██╔════╝██║   ██║██╔════╝██║██╔═══██╗████╗  ██║
  ╚███╔╝ ██████╔╝███████║ ╚████╔╝       █████╗  ██║   ██║███████╗██║██║   ██║██╔██╗ ██║
  ██╔██╗ ██╔══██╗██╔══██║  ╚██╔╝        ██╔══╝  ██║   ██║╚════██║██║██║   ██║██║╚██╗██║
 ██╔╝ ██╗██║  ██║██║  ██║   ██║         ██║     ╚██████╔╝███████║██║╚██████╔╝██║ ╚████║
 ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝         ╚═╝      ╚═════╝ ╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝
EOF
  echo -e "${NC}"
  echo "                    Xray Fusion - Uninstaller"
  echo ""

  # Check if running as root (233boy style)
  [[ ${EUID} -ne 0 ]] && error_exit "Not running as ROOT user, please run this script with sudo"

  local rc
  if check_installation; then
    rc=0
  else
    rc=$?
    log_debug "check_installation rc=${rc}"
    log_debug "exit rc=${rc}"
    exit "${rc}"
  fi
  get_installation_info
  if confirm_uninstallation; then
    rc=0
  else
    rc=$?
    log_debug "confirm_uninstallation rc=${rc}"
    log_debug "exit rc=${rc}"
    exit "${rc}"
  fi
  run_xrf_uninstall || error_exit "Installed xrf uninstall failed; no manual cleanup was attempted"

  # Remove only the global link created for this selected installation.
  cleanup_symlinks /usr/local/bin/xrf

  remove_installation_directory
  show_summary

  log_info "Uninstallation completed successfully!"
}

# Run main function with all arguments
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "${@}"
fi
