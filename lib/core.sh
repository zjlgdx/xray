#!/usr/bin/env bash
# Core utils: strict-mode (only via init), logging, retry
# NOTE: This file is sourced. Strict mode (set -euo pipefail) is set by core::init()
#       which must be called by the main script.

# Source guard: prevent double-sourcing
[[ -n "${_XRF_CORE_LOADED:-}" ]] && return 0
readonly _XRF_CORE_LOADED=1

##
# Initialize strict mode and parse global flags
#
# Sets up bash strict mode (set -euo pipefail -E) and parses
# global flags like --json and --debug. Must be called at the
# start of every main script.
#
# Arguments:
#   $@ - Command-line arguments (optional)
#
# Globals:
#   XRF_JSON - Set to "true" if --json flag present
#   XRF_DEBUG - Set to "true" if --debug flag present
#
# Returns:
#   0 - Always succeeds
#
# Side Effects:
#   - Enables bash strict mode (set -euo pipefail -E)
#   - Sets up ERR trap for error handling
#
# Example:
#   core::init "${@}"
##
core::init() {
  set -euo pipefail -E
  export XRF_JSON="${XRF_JSON:-false}"
  export XRF_DEBUG="${XRF_DEBUG:-false}"
  for arg in "${@}"; do
    case "${arg}" in
      --json) XRF_JSON=true ;;
      --debug) XRF_DEBUG=true ;;
      *) ;;
    esac
  done
  trap 'core::error_handler "${?}" "${LINENO}" "${BASH_COMMAND}"' ERR
}

##
# Check if bash strict mode is enabled
#
# Verifies that set -e, set -u, and set -o pipefail are enabled.
# Useful for defensive programming when libraries are sourced
# without proper initialization.
#
# Arguments:
#   None
#
# Returns:
#   0 - Strict mode is fully enabled
#   1 - One or more strict mode options are disabled
#
# Example:
#   if ! core::is_strict_mode; then
#     echo "Warning: strict mode not enabled" >&2
#   fi
##
core::is_strict_mode() {
  # Check if errexit (set -e) is enabled
  [[ $- == *e* ]] || return 1
  # Check if nounset (set -u) is enabled
  [[ $- == *u* ]] || return 1
  # Check if pipefail is enabled
  [[ "$(set -o | grep pipefail)" == *"on"* ]] || return 1
  return 0
}

##
# Ensure strict mode is enabled, with optional warning
#
# Checks if strict mode is enabled and optionally logs a warning
# if not. Controlled by XRF_STRICT_CHECK environment variable.
# Does not modify shell options - just validates and warns.
#
# Arguments:
#   $1 - Context/module name for warning message (string, optional)
#
# Globals:
#   XRF_STRICT_CHECK - If "true", log warning when strict mode disabled
#
# Returns:
#   0 - Strict mode is enabled
#   1 - Strict mode is disabled (warning logged if XRF_STRICT_CHECK=true)
#
# Example:
#   core::ensure_strict_mode "backup" || return 1
##
core::ensure_strict_mode() {
  local context="${1:-}"

  if core::is_strict_mode; then
    return 0
  fi

  # Only warn if XRF_STRICT_CHECK is enabled (opt-in for backwards compatibility)
  if [[ "${XRF_STRICT_CHECK:-false}" == "true" ]]; then
    local ctx_json="{}"
    if [[ -n "${context}" ]]; then
      ctx_json="$(printf '{"module":"%s","hint":"call core::init() at script start"}' "$(core::json_escape "${context}")")"
    else
      ctx_json='{"hint":"call core::init() at script start"}'
    fi
    # Use echo to stderr since core::log may depend on strict mode being set
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] warn     strict mode not enabled ${ctx_json}" >&2
  fi

  return 1
}

##
# ERR trap handler for error logging
#
# Internal function called by ERR trap to log error details before exit.
# Uses critical level to indicate severe error condition.
#
# Arguments:
#   $1 - Return code (number, required)
#   $2 - Line number (number, required)
#   $3 - Failed command (string, required)
#
# Returns:
#   Never returns (exits with return code from $1)
#
# Example:
#   trap 'core::error_handler "${?}" "${LINENO}" "${BASH_COMMAND}"' ERR
##
core::error_handler() {
  local return_code="${1}" line_number="${2}" command="${3}"
  # Use critical level for ERR trap (doesn't exit, trap will handle that)
  # Use core::json_escape for complete JSON escaping (CWE-345)
  core::log critical "ERR trap" "$(printf '{"rc":%d,"line":%d,"cmd":"%s"}' "${return_code}" "${line_number}" "$(core::json_escape "${command}")")"
  exit "${return_code}"
}

##
# Escape a string for safe JSON embedding
#
# Escapes all JSON special characters according to RFC 8259:
# - Backslash (\) -> \\
# - Double quote (") -> \"
# - Newline -> \n
# - Carriage return -> \r
# - Tab -> \t
# - Control characters (0x00-0x1F) -> \uXXXX
#
# Arguments:
#   $1 - String to escape (string, required)
#
# Output:
#   Escaped string to stdout (safe for JSON embedding)
#
# Returns:
#   0 - Always succeeds
#
# Example:
#   escaped="$(core::json_escape "line1\nline2")"
#   printf '{"msg":"%s"}' "$(core::json_escape "${user_input}")"
##
core::json_escape() {
  local input="${1:-}"
  local output=""
  local i char code

  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "${char}" in
      $'\\') output+='\\' ;;
      '"') output+='\"' ;;
      $'\n') output+='\n' ;;
      $'\r') output+='\r' ;;
      $'\t') output+='\t' ;;
      *)
        # Check for control characters (0x00-0x1F)
        # Use printf to get ASCII value
        code=$(printf '%d' "'${char}" 2> /dev/null || echo 0)
        if [[ ${code} -ge 0 && ${code} -le 31 ]]; then
          # Format as \uXXXX
          output+=$(printf '\\u%04x' "${code}")
        else
          output+="${char}"
        fi
        ;;
    esac
  done

  printf '%s' "${output}"
}

##
# Generate ISO 8601 UTC timestamp
#
# Returns:
#   ISO 8601 timestamp string (YYYY-MM-DDTHH:MM:SSZ)
#
# Example:
#   ts="$(core::ts)"  # "2025-11-10T12:34:56Z"
##
core::ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

##
# Format log message for output (internal helper)
#
# Internal function used by core::log to format messages.
# Separated to reduce cyclomatic complexity and improve testability.
#
# Arguments:
#   $1 - Log level (string, required)
#   $2 - Message (string, required)
#   $3 - Context JSON (string, required)
#
# Globals:
#   XRF_JSON - If "true", output JSON format
#
# Output:
#   Formatted log line to stdout (caller redirects to stderr)
#
# Returns:
#   0 - Always succeeds
##
core::log_format() {
  local lvl="${1}"
  local msg="${2}"
  local ctx="${3}"

  # Normalize fatal/critical to uppercase for visibility in text output
  local display_lvl="${lvl}"
  if [[ "${lvl}" == "fatal" || "${lvl}" == "critical" ]]; then
    display_lvl="${lvl^^}"
  fi

  # Check if context is empty (whitespace-only or empty object)
  local ctx_is_empty="false"
  local ctx_trimmed="${ctx//[[:space:]]/}"
  [[ -z "${ctx_trimmed}" || "${ctx_trimmed}" == "{}" ]] && ctx_is_empty="true"

  if [[ "${XRF_JSON}" == "true" ]]; then
    local json_ctx="${ctx}"
    [[ "${ctx_is_empty}" == "true" ]] && json_ctx="{}"
    printf '{"ts":"%s","level":"%s","msg":"%s","ctx":%s}\n' "$(core::ts)" "${lvl}" "${msg}" "${json_ctx}"
  else
    if [[ "${ctx_is_empty}" == "true" ]]; then
      printf '[%s] %-8s %s\n' "$(core::ts)" "${display_lvl}" "${msg}"
    else
      printf '[%s] %-8s %s %s\n' "$(core::ts)" "${display_lvl}" "${msg}" "${ctx}"
    fi
  fi
}

##
# Structured logging to stderr
#
# Logs messages in text or JSON format depending on XRF_JSON.
# All output goes to stderr to avoid contaminating function
# return values. Debug messages are filtered unless XRF_DEBUG=true.
#
# Supports log levels: debug, info, warn, error, critical, fatal
# - fatal: Immediately exits with code 1 after logging
# - critical: Logs severe error but does not exit
# - error/warn/info/debug: Standard log levels
#
# Arguments:
#   $1 - Log level (string, required) - debug|info|warn|error|critical|fatal
#   $2 - Message (string, required)
#   $3 - Context JSON (string, optional, default: "{}")
#
# Globals:
#   XRF_JSON - If "true", output JSON format
#   XRF_DEBUG - If "true", show debug messages
#
# Output:
#   Log line to stderr (text or JSON format)
#
# Returns:
#   0 - Success (debug/info/warn/error/critical)
#   Exits 1 - If level is fatal
#
# Example:
#   core::log info "Operation completed" '{"duration_ms":123}'
#   core::log error "Failed to read file" "$(printf '{"file":"%s"}' "${path}")"
#   core::log critical "Database corrupted" '{"db":"/var/lib/app/data.db"}'
#   core::log fatal "Missing required configuration"  # Exits immediately
##
core::log() {
  local lvl="${1}"
  shift
  local msg="${1}"
  shift || true
  local ctx="${1-}"
  [[ -z "${ctx}" ]] && ctx="{}"

  # Early return: filter debug messages unless XRF_DEBUG is true
  [[ "${lvl}" == "debug" && "${XRF_DEBUG}" != "true" ]] && return 0

  # Format and output to stderr (avoid contaminating function outputs)
  core::log_format "${lvl}" "${msg}" "${ctx}" >&2

  # Fatal errors exit immediately
  [[ "${lvl}" == "fatal" ]] && exit 1

  return 0
}

##
# Determine whether a failed attempt should be retried.
#
# Arguments:
#   $1 - Exit code from the failed command (number, required)
#   $2 - Command name (string, optional)
#
# Returns:
#   0 - Retriable failure
#   1 - Non-retriable failure
##
core::_retry_is_retriable() {
  local rc="${1:-1}" cmd_name="${2:-}"
  cmd_name="${cmd_name##*/}"

  if [[ "${cmd_name}" == "curl" ]]; then
    case "${rc}" in
      # Name resolution, connection, timeout, TLS/connect reset classes.
      6 | 7 | 28 | 35 | 52 | 56) return 0 ;;
      # curl -f HTTP errors are usually deterministic (4xx/5xx).
      22) return 1 ;;
    esac
  fi

  return 0
}

##
# Retry command with exponential backoff and jitter.
#
# Uses Google SRE-style retry pacing:
#   delay = min(base_delay^(attempt-1), max_delay)
#   sleep = delay + random(0..jitter_max_ms)/1000
#
# Arguments:
#   $1 - Maximum attempts (number, optional, default: 3)
#   $@ - Command and arguments to execute (required)
#
# Environment:
#   XRF_RETRY_BASE_DELAY     Base multiplier for backoff (default: 2)
#   XRF_RETRY_MAX_DELAY      Maximum backoff in seconds (default: 32)
#   XRF_RETRY_JITTER_MAX_MS  Maximum jitter in milliseconds (default: 1000)
#
# Returns:
#   0 - Command succeeded within max_attempts
#   N - Last command exit code when attempts are exhausted / non-retriable
#
# Example:
#   core::retry 5 curl -fsSL https://example.com/file
#   core::retry wget -O /tmp/file https://example.com/file  # Uses default 3 attempts
##
core::retry() {
  local max_attempts=3
  if [[ $# -gt 0 && "${1}" =~ ^[0-9]+$ ]]; then
    max_attempts="${1}"
    shift
  fi

  # Keep historical behavior: no command means nothing to retry.
  [[ $# -gt 0 ]] || return 0
  [[ "${max_attempts}" -ge 1 ]] || return 1

  local base_delay="${XRF_RETRY_BASE_DELAY:-2}"
  local max_delay="${XRF_RETRY_MAX_DELAY:-32}"
  local jitter_max_ms="${XRF_RETRY_JITTER_MAX_MS:-1000}"
  [[ "${base_delay}" =~ ^[0-9]+$ && "${base_delay}" -ge 1 ]] || base_delay=2
  [[ "${max_delay}" =~ ^[0-9]+$ && "${max_delay}" -ge 1 ]] || max_delay=32
  [[ "${jitter_max_ms}" =~ ^[0-9]+$ ]] || jitter_max_ms=1000

  local attempt=1 rc=0 delay=0 jitter_ms=0 sleep_value cmd_name
  cmd_name="${1}"

  while true; do
    "${@}" && return 0
    rc=$?

    if ((attempt >= max_attempts)); then
      return "${rc}"
    fi

    if ! core::_retry_is_retriable "${rc}" "${cmd_name}"; then
      return "${rc}"
    fi

    delay=$((base_delay ** (attempt - 1)))
    ((delay > max_delay)) && delay="${max_delay}"

    jitter_ms=0
    if ((jitter_max_ms > 0)); then
      jitter_ms=$((RANDOM % (jitter_max_ms + 1)))
    fi

    if ((jitter_ms > 0)); then
      printf -v sleep_value '%d.%03d' "${delay}" "${jitter_ms}"
    else
      sleep_value="${delay}"
    fi

    sleep "${sleep_value}"
    attempt=$((attempt + 1))
  done
}

##
# Validate that a required parameter is provided and non-empty
#
# Checks if a parameter value is non-empty and logs an error with
# context if validation fails. Reduces boilerplate validation code.
#
# Arguments:
#   $1 - Parameter value to check (string, required)
#   $2 - Parameter name for error message (string, required)
#   $3 - Function/context name for error message (string, optional)
#
# Returns:
#   0 - Parameter is valid (non-empty)
#   1 - Parameter is empty or missing
#
# Example:
#   core::require_param "${domain}" "domain" "install" || return 1
#   core::require_param "${port}" "port" || return 1
##
core::require_param() {
  local value="${1:-}"
  local param_name="${2:-param}"
  local context="${3:-}"

  if [[ -z "${value}" ]]; then
    local ctx_json="{}"
    if [[ -n "${context}" ]]; then
      ctx_json="$(printf '{"param":"%s","function":"%s"}' "$(core::json_escape "${param_name}")" "$(core::json_escape "${context}")")"
    else
      ctx_json="$(printf '{"param":"%s"}' "$(core::json_escape "${param_name}")")"
    fi
    core::log error "missing required parameter" "${ctx_json}"
    return 1
  fi
  return 0
}

##
# Validate multiple required parameters at once
#
# Checks that all parameter name=value pairs have non-empty values.
# Useful for validating function arguments in bulk.
#
# Arguments:
#   $@ - Parameter pairs in format "name=value" (at least one required)
#
# Returns:
#   0 - All parameters are valid
#   1 - One or more parameters are empty
#
# Example:
#   core::require_params "domain=${domain}" "port=${port}" || return 1
##
core::require_params() {
  local pair name value
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    if [[ -z "${value}" ]]; then
      core::log error "missing required parameter" "$(printf '{"param":"%s"}' "$(core::json_escape "${name}")")"
      return 1
    fi
  done
  return 0
}

##
# Execute a command with sudo, with proper error handling
#
# Wraps sudo execution with availability check and error logging.
# Returns appropriate error codes for different failure scenarios.
#
# Arguments:
#   $@ - Command and arguments to execute with sudo (required)
#
# Returns:
#   0 - Command succeeded
#   1 - Command failed (with error logged)
#   2 - sudo not available (with error logged)
#   3 - No command provided
#
# Example:
#   core::sudo_cmd mkdir -p /etc/myapp
#   core::sudo_cmd chown root:root /etc/myapp/config
#   if ! core::sudo_cmd systemctl restart myapp; then
#     echo "Failed to restart service"
#   fi
##
core::sudo_cmd() {
  # Check for command argument
  if [[ $# -eq 0 ]]; then
    core::log error "sudo_cmd called without command" "{}"
    return 3
  fi

  # Check if sudo is available
  if ! command -v sudo > /dev/null 2>&1; then
    core::log error "sudo not available" "$(printf '{"cmd":"%s"}' "$(core::json_escape "$*")")"
    return 2
  fi

  # Execute command with sudo
  local cmd_str="$*"
  if ! sudo "$@"; then
    local rc=$?
    core::log error "sudo command failed" "$(printf '{"cmd":"%s","rc":%d}' "$(core::json_escape "${cmd_str}")" "${rc}")"
    return 1
  fi

  return 0
}

##
# Check if sudo is available
#
# Simple check for sudo availability without executing anything.
#
# Returns:
#   0 - sudo is available
#   1 - sudo is not available
#
# Example:
#   if core::has_sudo; then
#     core::sudo_cmd mkdir -p /etc/app
#   fi
##
core::has_sudo() {
  command -v sudo > /dev/null 2>&1
}

##
# Ensure lock file is writable by current user
#
# Handles mixed sudo/non-sudo scenarios where lock file may be
# owned by root from a previous run. Attempts to fix ownership
# and permissions to allow the current user to write to the lock file.
#
# Arguments:
#   $1 - Lock file path (string, required)
#
# Returns:
#   0 - Lock file is writable or doesn't exist
#   1 - Failed to make lock file writable
#
# Security:
#   - Fixes CWE-283 (Unverified Ownership) by ensuring correct ownership
#   - Uses sudo only when necessary (principle of least privilege)
#   - Safe to call multiple times (idempotent)
#
# Example:
#   core::ensure_lock_writable "/var/lib/xray-fusion/locks/install.lock"
##
core::ensure_lock_writable() {
  local lock="${1}"

  # If file doesn't exist, nothing to fix
  [[ ! -f "${lock}" ]] && return 0

  # Fix ownership (may be root-owned from previous sudo run)
  if ! chown "$(id -u):$(id -g)" "${lock}" 2> /dev/null; then
    if ! core::has_sudo || ! sudo chown "$(id -u):$(id -g)" "${lock}" 2> /dev/null; then
      core::log warn "cannot fix lock file ownership" "$(printf '{"lock":"%s"}' "$(core::json_escape "${lock}")")"
      return 1
    fi
  fi

  # Fix permissions (make writable)
  if ! chmod 0644 "${lock}" 2> /dev/null; then
    if ! core::has_sudo || ! sudo chmod 0644 "${lock}" 2> /dev/null; then
      core::log warn "cannot fix lock file permissions" "$(printf '{"lock":"%s"}' "$(core::json_escape "${lock}")")"
      return 1
    fi
  fi

  return 0
}

##
# Execute command with exclusive file lock
#
# Acquires a file-based lock before executing the command,
# ensuring mutual exclusion. Handles sudo/non-sudo mixed
# scenarios by fixing ownership and permissions atomically.
#
# Arguments:
#   $1 - Lock file path (string, required)
#   $@ - Command and arguments to execute (required)
#
# Returns:
#   0 - Command succeeded
#   1 - Command failed
#   2 - Missing command argument
#
# Security:
#   - Opens lock files without replacing an inode held by another process
#   - Fixes ownership to current user (handles sudo remnants - CWE-283)
#   - Executes in subshell with fd 200 to release lock automatically
#   - Ensures writable lock file for all legitimate users
#
# Example:
#   core::with_flock "/var/lib/app/locks/deploy.lock" deploy_function arg1 arg2
#   core::with_flock "$(state::lock)" configure_and_deploy
##
core::with_flock() {
  local lock="${1}"
  shift || true
  [[ $# -gt 0 ]] || {
    core::log error "with_flock missing command" "$(printf '{"lock":"%s"}' "$(core::json_escape "${lock}")")"
    return 2
  }
  local dir
  dir="$(dirname "${lock}")"
  if ! mkdir -p "${dir}" 2> /dev/null; then
    core::log warn "mkdir fallback sudo" "$(printf '{"dir":"%s"}' "$(core::json_escape "${dir}")")"
    if ! core::sudo_cmd mkdir -p "${dir}"; then
      core::log error "failed to create lock directory" "$(printf '{"dir":"%s"}' "$(core::json_escape "${dir}")")"
      return 1
    fi
  fi

  # An append open creates the file without replacing an inode another process
  # may already have locked after the existence check.
  if ! test -f "${lock}" 2> /dev/null; then
    if ! (
      umask 022
      : >> "${lock}"
    ) 2> /dev/null; then
      core::log warn "lock file creation needs sudo" "$(printf '{"file":"%s"}' "$(core::json_escape "${lock}")")"
      core::sudo_cmd bash -c 'umask 022; : >> "$1"' _ "${lock}" 2> /dev/null || true
    fi
  fi

  # Ensure lock file is writable (handles previous root runs - CWE-283)
  core::ensure_lock_writable "${lock}" || {
    core::log error "lock file not writable" "$(printf '{"lock":"%s"}' "$(core::json_escape "${lock}")")"
    return 1
  }

  local lock_timeout="${XRF_FLOCK_TIMEOUT_SEC:-30}"
  [[ "${lock_timeout}" =~ ^[0-9]+$ && "${lock_timeout}" -ge 1 ]] || lock_timeout=30

  if command -v flock > /dev/null 2>&1; then
    (
      exec 200>> "${lock}"
      if ! flock -w "${lock_timeout}" -x 200; then
        core::log error "timed out waiting for lock" "$(printf '{"lock":"%s","timeout_sec":%d}' "$(core::json_escape "${lock}")" "${lock_timeout}")"
        exit 1
      fi
      "${@}"
    )
    return $?
  fi

  # macOS and some minimal environments do not provide flock(1).
  # Fall back to directory lock with polling to preserve mutual exclusion.
  local lock_dir="${lock}.d"
  local lock_started="${SECONDS}"
  while ! mkdir "${lock_dir}" 2> /dev/null; do
    if ((SECONDS - lock_started >= lock_timeout)); then
      core::log error "timed out waiting for lock" "$(printf '{"lock":"%s","timeout_sec":%d}' "$(core::json_escape "${lock}")" "${lock_timeout}")"
      return 1
    fi
    sleep 0.1
  done

  local rc had_errexit=false
  [[ "$-" == *e* ]] && had_errexit=true
  set +e
  (
    [[ "${had_errexit}" == true ]] && set -e
    "${@}"
  )
  rc=$?
  [[ "${had_errexit}" == true ]] && set -e
  rmdir "${lock_dir}" 2> /dev/null || true
  return "${rc}"
}
