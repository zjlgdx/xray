#!/usr/bin/env bash
# xray-fusion online installer
# Usage: curl -sL https://raw.githubusercontent.com/xrf9268-hue/xray/main/install.sh | bash -s -- [options]

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="${XRF_REPO_URL:-https://github.com/xrf9268-hue/xray.git}"
BRANCH="${XRF_BRANCH:-main}"
INSTALL_DIR="${XRF_INSTALL_DIR:-/usr/local/xray-fusion}"

# Runtime variables (will be set by args::parse)
TOPOLOGY=""
DOMAIN=""
VERSION=""
PLUGINS=""
DEBUG=""
PROXY=""
XRF_YES="false"
ALLOW_UNSIGNED_TAG="${XRF_ALLOW_UNSIGNED_TAG:-false}"
EXPECTED_COMMIT=""
DOWNLOAD_COMMIT=""
TARBALL_ROOT_DIR=""
INTEGRITY_VERIFIED="false"
REF_TYPE="heads"
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

  # Check downloader availability (need at least one)
  local has_downloader=false
  for tool in git curl wget; do
    if command -v "${tool}" > /dev/null 2>&1; then
      has_downloader=true
      log_debug "Found download tool: ${tool}"
      break
    fi
  done

  if [[ "${has_downloader}" == "false" ]]; then
    log_error "Need at least one download tool: git, curl, or wget"
    missing+=("git or curl or wget")
  fi

  # Check basic utilities
  for tool in mktemp tar gzip; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
      log_warn "Missing tool: ${tool}"
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
    echo "sudo apt-get update && sudo apt-get install -y git curl wget tar gzip"
    echo ""
    echo "# CentOS/RHEL/Rocky"
    echo "sudo yum install -y git curl wget tar gzip"
    echo ""
    echo "# Arch Linux"
    echo "sudo pacman -S git curl wget tar gzip"
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
  TOPOLOGY="reality-only"
  DOMAIN=""
  VERSION="latest"
  PLUGINS=""
  DEBUG="false"
  XRF_YES="false"
  ALLOW_UNSIGNED_TAG="${XRF_ALLOW_UNSIGNED_TAG:-false}"
}

# Parse command line arguments
args::parse() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --topology|-t)
        args::validate_topology "${2:-}" || return 1
        TOPOLOGY="${2}"
        shift 2
        ;;
      --domain|-d)
        args::validate_domain "${2:-}" || return 1
        DOMAIN="${2}"
        shift 2
        ;;
      --version|-v)
        args::validate_version "${2:-}" || return 1
        VERSION="${2}"
        shift 2
        ;;
      --plugins|-p)
        PLUGINS="${2:-}"
        shift 2
        ;;
      --proxy)
        PROXY="${2:-}"
        shift 2
        ;;
      --allow-unsigned-release|--allow-unsigned-tag)
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
      --)
        shift
        break
        ;;
      *)
        log_error "Unknown argument: ${1}"
        return 1
        ;;
    esac
  done

  # Validate configuration
  args::validate_config || return 1
  return 0
}

# Validation functions
args::validate_topology() {
  local topology="${1:-}"
  [[ -n "${topology}" ]] || { log_error "Topology cannot be empty"; return 1; }
  case "${topology}" in
    reality-only|vision-reality) return 0 ;;
    *) log_error "Invalid topology: ${topology}. Must be 'reality-only' or 'vision-reality'"; return 1 ;;
  esac
}

##
# Validate domain name (RFC-compliant)
#
# This is a standalone version that mirrors lib/validators.sh::validators::domain()
# to ensure install.sh can validate domains without dependencies.
#
# IMPORTANT: Keep this in sync with lib/validators.sh for consistent security.
#
# Checks:
# - RFC 1035: Format and length restrictions
# - RFC 1918: Private IPv4 networks
# - RFC 3927: Link-local addresses (169.254.0.0/16)
# - RFC 6761: Special-use domain names (.test, .invalid)
# - RFC 4193/4291: IPv6 private/link-local addresses
##
args::validate_domain() {
  local domain="${1:-}"

  # Empty domain is allowed (optional parameter)
  [[ -z "${domain}" ]] && return 0

  # Length check (DNS specification: total length <= 253)
  if [[ ${#domain} -gt 253 ]]; then
    log_error "Domain too long (max 253 characters): ${domain}"
    return 1
  fi

  # RFC 1035 compliant format
  if [[ ! "${domain}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    log_error "Invalid domain format (RFC 1035): ${domain}"
    return 1
  fi

  # Reject private/internal/special-use domains
  case "${domain}" in
    # Loopback and special addresses
    localhost|*.local|127.*|0.0.0.0)
      log_error "Loopback/local domain not allowed: ${domain}"
      return 1
      ;;
    # RFC 1918 private networks
    10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*)
      log_error "RFC 1918 private network not allowed: ${domain}"
      return 1
      ;;
    # RFC 3927 link-local addresses
    169.254.*)
      log_error "RFC 3927 link-local address not allowed: ${domain}"
      return 1
      ;;
    # RFC 6761 special-use domain names
    *.test|*.invalid)
      log_error "RFC 6761 special-use TLD not allowed: ${domain}"
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
    log_error "IPv6 private/link-local address not allowed: ${domain}"
    return 1
  fi

  return 0
}

args::validate_version() {
  local version="${1:-}"
  [[ -n "${version}" ]] || { log_error "Version cannot be empty"; return 1; }
  [[ "${version}" == "latest" ]] && return 0
  [[ "${version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    log_error "Invalid version format: ${version}. Use 'latest' or 'vX.Y.Z'"
    return 1
  }
}

args::validate_config() {
  if [[ "${TOPOLOGY}" == "vision-reality" && -z "${DOMAIN}" ]]; then
    log_error "Vision-reality topology requires --domain parameter"
    return 1
  fi
}

# Show help
args::show_help() {
  cat << EOF
xray-fusion online installer

Usage:
  curl -sL https://raw.githubusercontent.com/xrf9268-hue/xray/main/install.sh | bash -s -- [options]

Options:
  --topology, -t <type>         Installation topology (reality-only|vision-reality)
  --domain, -d <domain>         Domain for vision-reality topology (required)
  --version, -v <version>       Xray version to install (default: latest)
  --plugins, -p <list>          Comma-separated list of plugins to enable
  --proxy <url>                 Use proxy for downloads
  --install-dir <path>          Installation directory (default: /usr/local/xray-fusion)
  --allow-unsigned-release      Skip required GPG verification for tagged releases
  --yes, -y                     Auto-confirm installation (skip prompt)
  --debug                       Enable debug output
  --help, -h                    Show this help

Examples:
  # Reality-only installation
  curl -sL install.sh | bash -s -- --topology reality-only

  # Vision-Reality with domain and plugins
  curl -sL install.sh | bash -s -- --topology vision-reality --domain your.domain.com --plugins cert-auto

  # Specific version
  curl -sL install.sh | bash -s -- --topology reality-only --version v1.8.1

  # Non-interactive installation
  curl -sL install.sh | bash -s -- --topology reality-only --yes

Environment Variables:
  XRF_REPO_URL      Repository URL (default: https://github.com/xrf9268-hue/xray.git)
  XRF_BRANCH        Branch to use (default: main)
  XRF_INSTALL_DIR   Installation directory (default: /usr/local/xray-fusion)

Xray Configuration Variables:
  XRAY_SNI          SNI domain (default: www.apple.com)
  XRAY_PORT         Listen port (default: 443)
  XRAY_UUID         User UUID (auto-generated if not set)
  XRAY_*            All other Xray configuration variables

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
  # Set XRAY_DOMAIN for Xray configuration
  if [[ -n "${DOMAIN}" ]]; then
    export XRAY_DOMAIN="${DOMAIN}"
  fi

  # Set debug mode
  if [[ "${DEBUG}" == "true" ]]; then
    export XRF_DEBUG="true"
  fi

  REF_TYPE="$(detect_ref_type "${BRANCH}")"
  if [[ "$(is_tagged_ref "${BRANCH}")" == "true" && "${ALLOW_UNSIGNED_TAG}" != "true" ]]; then
    REQUIRE_SIGNED_TAG="true"
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

  local deps="curl wget git jq unzip openssl"
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

extract_commit_from_tar_root() {
  local root_name="${1:-}"
  [[ "${root_name}" =~ -([0-9a-fA-F]{40})$ ]] || return 1
  echo "${BASH_REMATCH[1]}"
  return 0
}

extract_repo_slug() {
  local url="${1:-}"
  if [[ "${url}" =~ github\.com[:/]+([^/]+)/([^/.]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

fetch_expected_commit() {
  if [[ -n "${EXPECTED_COMMIT}" ]]; then
    return 0
  fi

  if [[ -n "${XRF_EXPECTED_COMMIT:-}" ]]; then
    EXPECTED_COMMIT="${XRF_EXPECTED_COMMIT}"
    if [[ ! "${EXPECTED_COMMIT}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      log_error "Invalid XRF_EXPECTED_COMMIT format; must be 40-hex commit hash"
      return 1
    fi
    return 0
  fi

  local slug
  if ! slug="$(extract_repo_slug "${REPO_URL}")"; then
    log_error "XRF_EXPECTED_COMMIT is required when repository is not hosted on GitHub"
    return 1
  fi

  local api_url="https://api.github.com/repos/${slug}/commits/${BRANCH}"
  local response=""
  log_info "Fetching expected commit from GitHub API (${BRANCH})"

  # Try GitHub API with retries (3 attempts, exponential backoff)
  local attempt=0
  local max_retries=3
  local delay=2
  while [[ ${attempt} -lt ${max_retries} ]]; do
    attempt=$((attempt + 1))
    log_debug "GitHub API attempt ${attempt}/${max_retries}"

    if command -v curl > /dev/null 2>&1; then
      response="$(curl -fsSL --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github.v3+json" \
        "${api_url}" 2> /dev/null || true)"
    elif command -v wget > /dev/null 2>&1; then
      response="$(wget -qO- --timeout=30 \
        --header="Accept: application/vnd.github.v3+json" \
        "${api_url}" 2> /dev/null || true)"
    else
      log_error "No HTTP client available to fetch expected commit (need curl or wget)"
      return 1
    fi

    EXPECTED_COMMIT="$(echo "${response}" | grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | head -1 | grep -oE '[0-9a-f]{40}' || true)"
    if [[ "${EXPECTED_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
      break
    fi

    if [[ ${attempt} -lt ${max_retries} ]]; then
      log_warn "GitHub API attempt ${attempt} failed, retrying in ${delay}s..."
      sleep "${delay}"
      delay=$((delay * 2))
    fi
  done

  # Fallback to git ls-remote if API failed
  if [[ ! "${EXPECTED_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    log_warn "GitHub API failed after ${max_retries} attempts, trying git ls-remote..."
    if command -v git > /dev/null 2>&1; then
      EXPECTED_COMMIT="$(git ls-remote "${REPO_URL}" "refs/heads/${BRANCH}" 2> /dev/null | awk '{print $1}' || true)"
    fi
  fi

  if [[ ! "${EXPECTED_COMMIT}" =~ ^[0-9a-f]{40}$ ]]; then
    log_error "Failed to determine expected commit from GitHub API and git ls-remote"
    log_error "Set XRF_EXPECTED_COMMIT manually to continue after verifying the correct hash"
    return 1
  fi

  log_info "Expected commit: ${EXPECTED_COMMIT}"
  return 0
}

enforce_integrity_checks() {
  local repo_dir="${1:-}"
  local actual_commit="${2:-}"
  local expected_commit="${3:-}"
  local require_signature="${4:-false}"

  if [[ -z "${expected_commit}" ]]; then
    log_error "Missing expected commit for verification (set XRF_EXPECTED_COMMIT or ensure GitHub API is reachable)"
    return 1
  fi

  if [[ -z "${actual_commit}" ]]; then
    log_error "Unable to determine downloaded commit hash for verification"
    log_error "Ensure git metadata is available or retry with git-based download"
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
  log_info "Downloading xray-fusion from ${REPO_URL} (branch: ${BRANCH})..."

  log_debug "Using temporary directory: ${TMP_DIR}"

  # Set proxy if specified
  if [[ -n "${PROXY}" ]]; then
    export https_proxy="${PROXY}"
    export http_proxy="${PROXY}"
    log_info "Using proxy: ${PROXY}"
  fi

  # Download with automatic fallback (git → tarball)
  log_debug "Starting download..."

  # Try git clone first (preferred) with retry
  local download_success=false
  if command -v git > /dev/null 2>&1; then
    log_debug "Attempting git clone (max 3 retries)..."
    if retry_command 3 2 git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${TMP_DIR}/xray-fusion"; then
      log_debug "git clone succeeded"
      download_success=true
    else
      log_warn "git clone failed, trying tarball download..."
    fi
  else
    log_debug "git not available, using tarball download"
  fi

  # Fallback to tarball if git failed
  if [[ "${download_success}" == "false" ]]; then
    local tarball_url="${REPO_URL%.git}/archive/refs/${REF_TYPE}/${BRANCH}.tar.gz"
    local tarball="${TMP_DIR}/archive.tar.gz"
    local tar_root=""

    log_debug "Downloading tarball: ${tarball_url}"

    # Try curl first with retry
    if command -v curl > /dev/null 2>&1; then
      if retry_command 3 2 curl -fsSL --connect-timeout 10 --max-time 300 "${tarball_url}" -o "${tarball}"; then
        log_debug "tarball download succeeded (curl)"
        download_success=true
      else
        log_warn "curl download failed (after retries)"
        rm -f "${tarball}"
      fi
    fi

    # Fallback to wget with retry
    if [[ "${download_success}" == "false" ]] && command -v wget > /dev/null 2>&1; then
      if retry_command 3 2 wget -q --timeout=10 "${tarball_url}" -O "${tarball}"; then
        log_debug "tarball download succeeded (wget)"
        download_success=true
      else
        log_warn "wget download failed (after retries)"
        rm -f "${tarball}"
      fi
    fi

    # Extract tarball if downloaded
    if [[ "${download_success}" == "true" ]]; then
      tar_root=$(tar -tzf "${tarball}" | head -1 | cut -d/ -f1 2> /dev/null || true)
      log_debug "Extracting tarball..."
      if tar -xzf "${tarball}" -C "${TMP_DIR}" 2> /dev/null; then
        # Rename extracted directory
        mv "${TMP_DIR}/xray-fusion-${BRANCH}" "${TMP_DIR}/xray-fusion" 2> /dev/null \
          || mv "${TMP_DIR}"/xray-fusion-* "${TMP_DIR}/xray-fusion" 2> /dev/null
        rm -f "${tarball}"
        TARBALL_ROOT_DIR="${tar_root}"
      else
        log_error "tarball extraction failed"
        rm -f "${tarball}"
        download_success=false
      fi
    fi
  fi

  # Check final result
  if [[ "${download_success}" == "false" ]]; then
    log_error "All download methods failed (git/curl/wget)"
    log_info "Please check your network connection or try using a proxy"
    error_exit "Download failed"
  fi

  # === Verify download integrity BEFORE sourcing any code ===
  # Security: Verify BEFORE executing any downloaded code to prevent MITM attacks

  # 1. Get actual commit hash (uses only system git, no downloaded code)
  if ! fetch_expected_commit; then
    error_exit "Unable to determine expected commit for verification"
  fi

  DOWNLOAD_COMMIT=""
  if [[ -d "${TMP_DIR}/xray-fusion/.git" ]]; then
    DOWNLOAD_COMMIT="$(git -C "${TMP_DIR}/xray-fusion" rev-parse HEAD 2> /dev/null || true)"
  elif [[ -n "${TARBALL_ROOT_DIR}" ]]; then
    if ! DOWNLOAD_COMMIT="$(extract_commit_from_tar_root "${TARBALL_ROOT_DIR}")"; then
      DOWNLOAD_COMMIT=""
    fi
  fi
  log_debug "Downloaded commit: ${DOWNLOAD_COMMIT:-unknown}"

  if ! enforce_integrity_checks "${TMP_DIR}/xray-fusion" "${DOWNLOAD_COMMIT}" "${EXPECTED_COMMIT}" "${REQUIRE_SIGNED_TAG}"; then
    error_exit "Integrity verification failed (commit/GPG)"
  fi
  INTEGRITY_VERIFIED="true"

  # === END: Verification ===
  # Note: Removed sourcing of lib/download.sh - all verification logic is self-contained

  # Verify download completeness
  if [[ ! -d "${TMP_DIR}/xray-fusion" ]] || [[ ! -f "${TMP_DIR}/xray-fusion/bin/xrf" ]]; then
    error_exit "Downloaded files incomplete or corrupted"
  fi

  log_info "Download completed"
}

# Install xray-fusion
install_xray_fusion() {
  log_info "Installing xray-fusion to ${INSTALL_DIR}..."

  # Create installation directory
  if [[ -d "${INSTALL_DIR}" ]]; then
    INSTALL_DIR_PREEXISTING="true"
  else
    INSTALL_DIR_PREEXISTING="false"
  fi
  mkdir -p "${INSTALL_DIR}"

  INSTALL_MARKER="${INSTALL_DIR}/.install_in_progress"
  : > "${INSTALL_MARKER}"

  # Copy files
  cp -r "${TMP_DIR}/xray-fusion"/* "${INSTALL_DIR}/"

  # Make scripts executable
  chmod +x "${INSTALL_DIR}/bin/xrf"
  find "${INSTALL_DIR}" -name "*.sh" -type f -exec chmod +x {} \;

  # Create symlink for global access
  if [[ -L "${SYMLINK_PATH}" ]]; then
    rm -f "${SYMLINK_PATH}"
  fi
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

  if [[ -L "${SYMLINK_PATH}" ]]; then
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
  log_info "Installing Xray with topology: ${TOPOLOGY}"

  local install_args=("--topology" "${TOPOLOGY}")

  if [[ -n "${DOMAIN}" ]]; then
    install_args+=("--domain" "${DOMAIN}")
  fi

  if [[ "${VERSION}" != "latest" ]]; then
    install_args+=("--version" "${VERSION}")
  fi

  if [[ -n "${PLUGINS}" ]]; then
    install_args+=("--plugins" "${PLUGINS}")
  fi

  if [[ "${DEBUG}" == "true" ]]; then
    install_args+=("--debug")
  fi

  if [[ "${XRF_YES}" == "true" ]]; then
    install_args+=("--yes")
  fi

  # Change to installation directory
  cd "${INSTALL_DIR}"

  if [[ "${INTEGRITY_VERIFIED}" != "true" ]]; then
    cleanup_partial_installation
    error_exit "Integrity checks did not complete successfully; aborting execution of xrf"
  fi

  # Run installation with unified arguments
  if "./bin/xrf" install "${install_args[@]}"; then
    log_info "Xray installation completed successfully"
    [[ -n "${INSTALL_MARKER}" && -f "${INSTALL_MARKER}" ]] && rm -f "${INSTALL_MARKER}"
    INSTALL_MARKER=""

    # Post-installation validation
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
  echo "  Topology: ${TOPOLOGY}"
  echo "  Version: ${VERSION}"
  echo "  Install Directory: ${INSTALL_DIR}"
  [[ -n "${DOMAIN}" ]] && echo "  Domain: ${DOMAIN}"
  [[ -n "${PLUGINS}" ]] && echo "  Enabled Plugins: ${PLUGINS}"
  [[ -n "${XRAY_SNI:-}" ]] && echo "  Custom SNI: ${XRAY_SNI}"
  [[ -n "${XRAY_PORT:-}" ]] && echo "  Custom Port: ${XRAY_PORT}"
  echo ""
  log_info "Next steps:"
  echo "  1. Check status: xrf status"
  echo "  2. View client links: xrf links"
  echo "  3. Manage plugins: xrf plugin list"
  echo ""
  log_info "For more information, run: xrf help"
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
  log_substep "Topology: ${TOPOLOGY}" "✓"
  [[ -n "${DOMAIN}" ]] && log_substep "Domain: ${DOMAIN}" "✓"
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
