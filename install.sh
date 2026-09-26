#!/usr/bin/env bash
# xray-fusion online installer
# Usage: export XRAY_SNI=your-verified-target.example
#        curl -fsSL https://raw.githubusercontent.com/zjlgdx/xray/main/install.sh | sudo -E bash -s -- [options]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="${XRF_REPO_URL:-https://github.com/zjlgdx/xray.git}"
BRANCH="${XRF_BRANCH:-main}"
INSTALL_DIR="${XRF_INSTALL_DIR:-/usr/local/xray-fusion}"

# Runtime variables (will be set by args::parse)
VERSION=""
DEBUG=""
PROXY=""
XRF_YES="false"
ALLOW_UNSIGNED_TAG="${XRF_ALLOW_UNSIGNED_TAG:-false}"
EXPECTED_COMMIT=""
DOWNLOAD_COMMIT=""
INTEGRITY_VERIFIED="false"
REQUIRE_SIGNED_TAG="false"

SYMLINK_PATH="/usr/local/bin/xrf"
INSTALL_DIR_PREEXISTING="false"
INSTALL_MARKER=""

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} ${*}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} ${*}"; }
log_error() { echo -e "${RED}[ERROR]${NC} ${*}"; }
log_debug() { [[ "${DEBUG}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${*}" || true; }

##
# Log installation step with progress indicator
#
# Displays a step counter [N/M] followed by the step description.
# Uses BLUE color for the progress indicator.
#
# Arguments:
#   $1 - Current step number
#   $2 - Total steps
#   $3 - Step description
#
# Example:
#   log_step 1 7 "Checking runtime environment"
#   # Output: [1/7] Checking runtime environment
##
log_step() {
  local current="${1}"
  local total="${2}"
  local desc="${3}"
  echo -e "${BLUE}[${current}/${total}]${NC} ${desc}"
}

##
# Log sub-step with indentation and status icon
#
# Displays a sub-step with 2-space indentation and a status icon:
# - • (bullet, default): in progress or neutral status
# - ✓ (checkmark): success
# - ✗ (cross): error
#
# Arguments:
#   $1 - Sub-step description
#   $2 - Status icon (optional): •, ✓, ✗, or text aliases (success, error)
#
# Example:
#   log_substep "ROOT permission" "✓"
#   log_substep "Checking..." "•"
#   log_substep "Failed" "error"
##
log_substep() {
  local desc="${1}"
  local icon="${2:-•}"

  case "${icon}" in
    success | ✓) echo -e "  ${GREEN}✓${NC} ${desc}" ;;
    error | ✗) echo -e "  ${RED}✗${NC} ${desc}" ;;
    *) echo -e "  ${BLUE}•${NC} ${desc}" ;;
  esac
}

##
# Show spinner animation for long-running tasks
#
# Displays a rotating spinner with a description. This function runs
# in an infinite loop and should be started in background. Kill the
# process when the task completes.
#
# The spinner is skipped when DEBUG mode is enabled to avoid interfering
# with debug output.
#
# Arguments:
#   $1 - Task description to show next to spinner
#
# Globals:
#   DEBUG - If "true", spinner is not shown
#
# Example:
#   show_spinner "Downloading..." &
#   SPINNER_PID=$!
#   long_running_command
#   kill ${SPINNER_PID} 2>/dev/null
#   printf "\r"  # Clear spinner line
##
show_spinner() {
  local desc="${1}"
  local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local i=0

  while true; do
    printf "\r  ${BLUE}${chars:$i:1}${NC} %s" "${desc}"
    i=$(((i + 1) % ${#chars}))
    sleep 0.1
  done
}

# Error handling
error_exit() {
  log_error "${1}"
  cleanup
  exit 1
}

cleanup() {
  # Stop spinner if running
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "${SPINNER_PID}" 2> /dev/null || true
    wait "${SPINNER_PID}" 2> /dev/null || true
  fi
  # Clean up temp directory (|| true prevents false condition from affecting exit code)
  [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}" || true
}

trap cleanup EXIT

# Retry function with exponential backoff
retry_command() {
  local max_retries="${1}"
  local initial_delay="${2}"
  shift 2
  local attempt=0
  local delay="${initial_delay}"

  while [[ ${attempt} -lt ${max_retries} ]]; do
    attempt=$((attempt + 1))
    log_debug "Attempt ${attempt}/${max_retries}: $*"

    if "$@"; then
      log_debug "Command succeeded (attempt ${attempt})"
      return 0
    fi

    if [[ ${attempt} -lt ${max_retries} ]]; then
      log_warn "Command failed, retrying in ${delay}s..."
      sleep "${delay}"
      delay=$((delay * 2)) # Exponential backoff
    fi
  done

  log_error "Command failed after ${max_retries} retries"
  return 1
}

# Check critical dependencies (embedded for early fail-fast)
check_dependencies() {
  log_info "Checking core dependencies..."

  local missing=()

  for tool in git mktemp; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
      missing+=("${tool}")
    fi
  done

  # Fail if any critical tool is missing
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing critical dependencies: ${missing[*]}"
    echo ""
    echo "Please install missing tools for your system:"
    echo ""
    echo "# Debian/Ubuntu"
    echo "sudo apt-get update && sudo apt-get install -y git mktemp"
    echo ""
    echo "# CentOS/RHEL/Rocky"
    echo "sudo yum install -y git mktemp"
    echo ""
    echo "# Arch Linux"
    echo "sudo pacman -S git mktemp"
    echo ""
    return 1
  fi

  # Check optional tools (warn but don't fail)
  local optional_missing=()
  for tool in jq openssl gpg; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
      optional_missing+=("${tool}")
    fi
  done

  if [[ ${#optional_missing[@]} -gt 0 ]]; then
    log_warn "Optional tools missing (functionality may be limited): ${optional_missing[*]}"
  fi

  log_info "Dependency check passed"
  return 0
}

# Load unified argument parsing (embedded for installation)
source_args_module() {
  # Create temporary args module for installation
  cat > "${TMP_DIR}/args.sh" << 'ARGS_EOF'
#!/usr/bin/env bash
# Temporary unified argument parsing for installation

# Initialize default values
args::init() {
  VERSION="latest"
  DEBUG="false"
  XRF_YES="false"
  ALLOW_UNSIGNED_TAG="${XRF_ALLOW_UNSIGNED_TAG:-false}"
}

args::parse() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --version|-v)
        args::validate_version "${2:-}" || return 1
        VERSION="${2}"
        shift 2
        ;;
      --proxy)
        PROXY="${2:-}"
        shift 2
        ;;
      --allow-unsigned-release)
        ALLOW_UNSIGNED_TAG="true"
        shift
        ;;
      --install-dir)
        INSTALL_DIR="${2:-}"
        shift 2
        ;;
      --debug)
        DEBUG="true"
        shift
        ;;
      --yes|-y)
        XRF_YES="true"
        shift
        ;;
      --help|-h)
        return 10
        ;;
      *)
        log_error "Unknown argument: ${1}"
        return 1
        ;;
    esac
  done
}

args::validate_version() {
  local version="${1:-}"
  [[ "${version}" == latest || "${version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    log_error "Invalid version format: ${version}. Use latest or vX.Y.Z"
    return 1
  }
}

# Show help
args::show_help() {
  cat << EOF
xray-fusion online installer

Usage:
  export XRAY_SNI=your-verified-target.example
  curl -fsSL https://raw.githubusercontent.com/zjlgdx/xray/main/install.sh | sudo -E bash -s -- [options]

Options:
  --version, -v <version>       Xray version (default: newest published release)
  --proxy <url>                 Proxy for repository download
  --install-dir <path>          Tool directory (default: /usr/local/xray-fusion)
  --allow-unsigned-release      Skip required GPG verification for tagged releases
  --yes, -y                     Auto-confirm fresh installation
  --debug                       Enable debug output
  --help, -h                    Show this help

Environment:
  XRAY_SNI          Required REALITY server name
  XRAY_REALITY_DEST Actual REALITY target (default: XRAY_SNI:443)
  XRF_REPO_URL      Repository URL (default: https://github.com/zjlgdx/xray.git)
  XRF_BRANCH        Branch or tag to use (default: main)
  XRF_INSTALL_DIR   Tool directory (default: /usr/local/xray-fusion)
  XRF_EXPECTED_COMMIT Optional pinned 40-hex commit for download integrity
EOF
}
ARGS_EOF

  source "${TMP_DIR}/args.sh"
}

# Show help
show_help() {
  args::show_help
}

# Parse command line arguments
parse_args() {
  args::init

  local rc=0
  args::parse "$@" || rc=$?

  if [[ ${rc} -eq 10 ]]; then
    show_help
    exit 0
  elif [[ ${rc} -ne 0 ]]; then
    show_help
    exit 1
  fi
}

# Setup environment from parsed arguments
setup_environment() {
  if [[ "${DEBUG}" == true ]]; then
    export XRF_DEBUG=true
  fi
  if [[ "$(is_tagged_ref "${BRANCH}")" == true && "${ALLOW_UNSIGNED_TAG}" != true ]]; then
    REQUIRE_SIGNED_TAG=true
  fi
}

# Early validation (inspired by 233boy style)
early_checks() {
  # Check if running as root
  [[ ${EUID} -ne 0 ]] && error_exit "Not running as ROOT user, please run this script with sudo"

  # Check package manager (apt-get or yum)
  local cmd
  cmd=$(type -P apt-get || type -P yum || type -P dnf)
  [[ -z "${cmd}" ]] && error_exit "This script only supports Ubuntu/Debian/CentOS/RHEL systems"

  # Check systemd
  if ! type -P systemctl > /dev/null 2>&1; then
    error_exit "This system is missing systemctl, please install systemd"
  fi

  # Check architecture (simplified)
  case $(uname -m) in
    x86_64 | amd64 | aarch64 | arm64) ;;
    *) error_exit "This script only supports 64-bit systems" ;;
  esac

  log_info "Basic environment check passed"
}

# System checks (simplified)
check_system() {
  log_info "Checking system requirements..."

  # Basic OS detection without strict validation
  if [[ -f /etc/os-release ]]; then
    # Load in subshell to avoid variable pollution
    local os_info
    os_info=$(source /etc/os-release 2> /dev/null && echo "${ID:-unknown} ${VERSION_ID:-unknown}")
    log_debug "Detected system: ${os_info}"
  else
    log_warn "Unable to detect OS version, continuing with installation..."
  fi

  log_info "System check completed"
}

# Install dependencies
install_dependencies() {
  log_info "Installing dependencies..."

  local deps="curl git jq unzip openssl"
  local missing_deps=""
  local pkg_manager=""

  # Detect package manager
  if command -v apt-get > /dev/null 2>&1; then
    pkg_manager="apt"
  elif command -v yum > /dev/null 2>&1; then
    pkg_manager="yum"
  elif command -v dnf > /dev/null 2>&1; then
    pkg_manager="dnf"
  else
    error_exit "No supported package manager found (apt/yum/dnf)"
  fi

  log_debug "Detected package manager: ${pkg_manager}"

  # Check for missing dependencies
  for dep in ${deps}; do
    if ! command -v "${dep}" > /dev/null 2>&1; then
      missing_deps="${missing_deps} ${dep}"
    fi
  done

  # Trim leading space
  missing_deps="${missing_deps# }"

  # Install missing dependencies
  if [[ -n "${missing_deps}" ]]; then
    log_info "Installing missing dependencies: ${missing_deps}"
    case "${pkg_manager}" in
      apt)
        apt-get update -qq || log_warn "apt-get update failed, continuing with installation..."
        # shellcheck disable=SC2086
        apt-get install -y ${missing_deps} || error_exit "Dependency installation failed"
        ;;
      yum)
        yum install -y epel-release || log_warn "epel-release installation failed, continuing..."
        # shellcheck disable=SC2086
        yum install -y ${missing_deps} || error_exit "Dependency installation failed"
        ;;
      dnf)
        # shellcheck disable=SC2086
        dnf install -y ${missing_deps} || error_exit "Dependency installation failed"
        ;;
      *)
        error_exit "Unsupported package manager: ${pkg_manager}"
        ;;
    esac
    log_info "Dependency installation completed"
  else
    log_info "All dependencies already installed"
  fi
}

is_tagged_ref() {
  local ref="${1:-}"
  [[ "${ref}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+)?$ ]] && echo "true" && return 0
  echo "false"
  return 0
}

detect_ref_type() {
  local ref="${1:-}"
  if [[ "$(is_tagged_ref "${ref}")" == "true" ]]; then
    echo "tags"
    return 0
  fi
  echo "heads"
}

fetch_expected_commit() {
  if [[ -n "${EXPECTED_COMMIT}" ]]; then
    return 0
  fi
  if [[ -n "${XRF_EXPECTED_COMMIT:-}" ]]; then
    EXPECTED_COMMIT="${XRF_EXPECTED_COMMIT}"
  else
    local ref output
    if [[ "$(detect_ref_type "${BRANCH}")" == tags ]]; then
      ref="refs/tags/${BRANCH}"
      output="$(git ls-remote "${REPO_URL}" "${ref}" "${ref}^{}")" || return 1
      EXPECTED_COMMIT="$(printf '%s\n' "${output}" | awk -v peeled="${ref}^{}" -v tag="${ref}" '$2 == peeled {print $1; found=1; exit} $2 == tag {unpeeled=$1} END {if (!found && unpeeled != "") print unpeeled}')"
    else
      ref="refs/heads/${BRANCH}"
      output="$(git ls-remote "${REPO_URL}" "${ref}")" || return 1
      EXPECTED_COMMIT="$(printf '%s\n' "${output}" | awk -v ref="${ref}" '$2 == ref {print $1; exit}')"
    fi
  fi
  if [[ ! "${EXPECTED_COMMIT}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    log_error "Invalid or unavailable expected commit; set a verified XRF_EXPECTED_COMMIT"
    return 1
  fi
  log_info "Expected commit: ${EXPECTED_COMMIT}"
}

enforce_integrity_checks() {
  local repo_dir="${1:-}"
  local actual_commit="${2:-}"
  local expected_commit="${3:-}"
  local require_signature="${4:-false}"

  if [[ -z "${expected_commit}" ]]; then
    log_error "Missing expected commit for verification (set XRF_EXPECTED_COMMIT or make git ls-remote available)"
    return 1
  fi

  if [[ -z "${actual_commit}" ]]; then
    log_error "Unable to determine downloaded commit hash for verification"
    log_error "Ensure git metadata is available"
    return 1
  fi

  if [[ "${actual_commit,,}" != "${expected_commit,,}" ]]; then
    log_error "Download integrity verification failed: commit hash mismatch"
    log_error "Expected: ${expected_commit}"
    log_error "Actual: ${actual_commit}"
    return 1
  fi

  log_info "✓ Commit verification passed"

  if [[ "${require_signature}" == "true" ]]; then
    if [[ ! -d "${repo_dir}/.git" ]]; then
      log_error "GPG verification required for tagged release but git metadata is missing"
      log_error "Install with git available or use --allow-unsigned-release to bypass"
      return 1
    fi

    if ! command -v gpg > /dev/null 2>&1; then
      log_error "GPG verification required for tagged release but gpg is not installed"
      log_error "Install gnupg or rerun with --allow-unsigned-release to bypass"
      return 1
    fi

    if git -C "${repo_dir}" verify-commit "${actual_commit}" > /dev/null 2>&1; then
      log_info "✓ GPG signature verification passed (tagged release)"
    else
      log_error "GPG verification failed or missing signatures for tagged release ${BRANCH}"
      log_error "If you trust this source, rerun with --allow-unsigned-release"
      return 1
    fi
  else
    if [[ -d "${repo_dir}/.git" ]] && command -v gpg > /dev/null 2>&1; then
      if git -C "${repo_dir}" verify-commit "${actual_commit}" > /dev/null 2>&1; then
        log_info "✓ GPG signature verification passed"
      else
        log_debug "GPG signature verification failed or commit not signed (optional check)"
      fi
    fi
  fi

  return 0
}

# Download xray-fusion
download_project() {
  log_info "Cloning xray-fusion from ${REPO_URL} (ref: ${BRANCH})..."
  if [[ -n "${PROXY}" ]]; then
    export https_proxy="${PROXY}" http_proxy="${PROXY}"
  fi
  if ! git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${TMP_DIR}/xray-fusion"; then
    error_exit "Repository clone failed"
  fi

  # Verify the exact checkout before executing anything from it.
  fetch_expected_commit || error_exit "Unable to determine expected commit"
  DOWNLOAD_COMMIT="$(git -C "${TMP_DIR}/xray-fusion" rev-parse HEAD)" || error_exit "Unable to read cloned commit"
  if ! enforce_integrity_checks "${TMP_DIR}/xray-fusion" "${DOWNLOAD_COMMIT}" "${EXPECTED_COMMIT}" "${REQUIRE_SIGNED_TAG}"; then
    error_exit "Integrity verification failed (commit/GPG)"
  fi
  INTEGRITY_VERIFIED=true
  [[ -f "${TMP_DIR}/xray-fusion/bin/xrf" ]] || error_exit "Downloaded files incomplete"
  log_info "Download completed"
}

# Install xray-fusion
install_xray_fusion() {
  log_info "Installing xray-fusion to ${INSTALL_DIR}..."

  # The online wrapper only installs a fresh tool. A repeat invocation must
  # leave the existing command available for xrf upgrade or recovery.
  if [[ -e "${INSTALL_DIR}" || -L "${INSTALL_DIR}" ]]; then
    log_error "Existing xray-fusion tool at ${INSTALL_DIR}; use xrf upgrade or uninstall it first"
    return 1
  fi
  if [[ -e "${SYMLINK_PATH}" || -L "${SYMLINK_PATH}" ]]; then
    log_error "Existing global command at ${SYMLINK_PATH}; refusing to replace it"
    return 1
  fi
  INSTALL_DIR_PREEXISTING="false"
  mkdir -p "${INSTALL_DIR}"

  INSTALL_MARKER="${INSTALL_DIR}/.install_in_progress"
  : > "${INSTALL_MARKER}"

  # Copy files
  cp -r "${TMP_DIR}/xray-fusion"/* "${INSTALL_DIR}/"

  # Make scripts executable
  chmod +x "${INSTALL_DIR}/bin/xrf"
  find "${INSTALL_DIR}" -name "*.sh" -type f -exec chmod +x {} \;

  # Create symlink for global access
  ln -sf "${INSTALL_DIR}/bin/xrf" "${SYMLINK_PATH}"

  # Verify symlink creation
  if [[ ! -L "${SYMLINK_PATH}" ]]; then
    log_warn "Failed to create global symlink: ${SYMLINK_PATH}"
  else
    log_debug "Created symlink: ${SYMLINK_PATH} -> ${INSTALL_DIR}/bin/xrf"
  fi

  log_info "xray-fusion installed successfully"
}

# Cleanup partial installation
cleanup_partial_installation() {
  log_warn "Cleaning up partial installation"

  if [[ "${INSTALL_DIR_PREEXISTING}" != "true" && -L "${SYMLINK_PATH}" ]]; then
    local target
    target="$(readlink -f "${SYMLINK_PATH}" 2> /dev/null || true)"
    local expected_target
    expected_target="$(readlink -f "${INSTALL_DIR}/bin/xrf" 2> /dev/null || true)"
    if [[ -n "${expected_target}" && "${target}" == "${expected_target}" ]]; then
      rm -f "${SYMLINK_PATH}"
      log_debug "Removed symlink: ${SYMLINK_PATH}"
    fi
  fi

  if [[ -n "${INSTALL_MARKER}" && -f "${INSTALL_MARKER}" ]]; then
    rm -f "${INSTALL_MARKER}"
    if [[ "${INSTALL_DIR_PREEXISTING}" != "true" ]]; then
      rm -rf "${INSTALL_DIR}"
      log_debug "Removed installation directory: ${INSTALL_DIR}"
    else
      log_warn "Preserving existing installation directory: ${INSTALL_DIR}"
    fi
  fi
}

# Run xray installation
run_xray_install() {
  log_info "Installing REALITY Xray for SNI ${XRAY_SNI}"
  local install_args=()
  [[ "${VERSION}" == latest ]] || install_args+=("--version" "${VERSION}")
  [[ "${DEBUG}" == true ]] && install_args+=("--debug")
  [[ "${XRF_YES}" == true ]] && install_args+=("--yes")
  cd "${INSTALL_DIR}"
  if [[ "${INTEGRITY_VERIFIED}" != true ]]; then
    cleanup_partial_installation
    error_exit "Integrity checks did not complete; refusing to execute xrf"
  fi
  if "./bin/xrf" install "${install_args[@]}"; then
    log_info "Xray installation completed successfully"
    [[ -n "${INSTALL_MARKER}" && -f "${INSTALL_MARKER}" ]] && rm -f "${INSTALL_MARKER}"
    INSTALL_MARKER=""
    validate_installation
  else
    cleanup_partial_installation
    error_exit "Xray installation failed"
  fi
}

# Validate installation
validate_installation() {
  log_debug "Validating installation..."

  # Check if xrf command works
  if ! "./bin/xrf" status > /dev/null 2>&1; then
    log_warn "xrf command validation failed"
    return 1
  fi

  # Check if global symlink works
  if [[ -L "${SYMLINK_PATH}" ]] && command -v xrf > /dev/null 2>&1; then
    log_debug "Global xrf command accessible"
  else
    log_warn "Global xrf command not accessible"
  fi

  # Check if service is running (if systemctl available)
  if command -v systemctl > /dev/null 2>&1; then
    if systemctl is-active --quiet xray 2> /dev/null; then
      log_debug "Xray service is running"
    else
      log_warn "Xray service is not running"
    fi
  fi

  log_debug "Installation validation completed"
}

# Show installation summary
show_summary() {
  log_info "Installation Summary:"
  echo "  REALITY SNI: ${XRAY_SNI}"
  echo "  Version: ${VERSION}"
  echo "  Install Directory: ${INSTALL_DIR}"
  echo "  1. Check status: xrf status"
  echo "  2. View client link: xrf links"
  echo "  3. View journal: xrf logs"
}

# Main function
main() {
  echo -e "${GREEN}"
  cat << 'EOF'
 ██╗  ██╗██████╗  █████╗ ██╗   ██╗      ███████╗██╗   ██╗███████╗██╗ ██████╗ ███╗   ██╗
 ╚██╗██╔╝██╔══██╗██╔══██╗╚██╗ ██╔╝      ██╔════╝██║   ██║██╔════╝██║██╔═══██╗████╗  ██║
  ╚███╔╝ ██████╔╝███████║ ╚████╔╝       █████╗  ██║   ██║███████╗██║██║   ██║██╔██╗ ██║
  ██╔██╗ ██╔══██╗██╔══██║  ╚██╔╝        ██╔══╝  ██║   ██║╚════██║██║██║   ██║██║╚██╗██║
 ██╔╝ ██╗██║  ██║██║  ██║   ██║         ██║     ╚██████╔╝███████║██║╚██████╔╝██║ ╚████║
 ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝         ╚═╝      ╚═════╝ ╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝
EOF
  echo -e "${NC}"
  echo "                    Xray Fusion - One-Click Installer"
  echo ""

  # Download and setup args module first
  TMP_DIR="$(mktemp -d)"
  source_args_module

  parse_args "${@}"

  if [[ -z "${XRAY_SNI:-}" ]]; then
    error_exit "XRAY_SNI is required for a fresh REALITY install"
  fi

  # === Step 1: Dependency check (fail-fast) ===
  log_step 1 7 "Checking core dependencies"
  check_dependencies || error_exit "Dependency check failed, cannot continue installation"
  log_substep "Download tools available" "✓"
  log_substep "System tools ready" "✓"

  # === Step 2: Environment checks ===
  log_step 2 7 "Checking runtime environment"
  early_checks
  log_substep "ROOT permission" "✓"
  log_substep "systemd available" "✓"
  log_substep "Architecture supported ($(uname -m))" "✓"

  # Setup environment from parsed arguments
  setup_environment

  # === Step 3: Configuration validation ===
  log_step 3 7 "Validating configuration parameters"
  log_substep "REALITY SNI: ${XRAY_SNI}" "✓"
  log_substep "Version: ${VERSION}" "✓"

  # === Step 4: System compatibility check ===
  log_step 4 7 "Checking system compatibility"
  check_system
  log_substep "Operating system compatible" "✓"

  # === Step 5: Install system dependencies ===
  log_step 5 7 "Installing required dependencies"
  install_dependencies

  # === Step 6: Download project ===
  log_step 6 7 "Downloading xray-fusion"
  log_substep "Repository: ${REPO_URL##*/}"
  log_substep "Branch: ${BRANCH}"

  # Show spinner during download (skip in debug mode)
  if [[ "${DEBUG}" != "true" ]]; then
    show_spinner "Downloading..." &
    SPINNER_PID=$!
  fi

  download_project

  # Stop spinner if it was started
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill ${SPINNER_PID} 2> /dev/null || true
    wait ${SPINNER_PID} 2> /dev/null || true
    printf "\r"
    unset SPINNER_PID
  fi

  log_substep "Download completed" "✓"

  # === Step 7: Install and configure ===
  log_step 7 7 "Installing and configuring Xray"
  install_xray_fusion
  log_substep "File installation completed" "✓"

  run_xray_install
  log_substep "Service started successfully" "✓"

  echo ""
  show_summary

  echo ""
  log_info "🎉 Installation completed!"
}

# Run main function with all arguments
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "${@}"
fi
