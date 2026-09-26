#!/usr/bin/env bash
# Error code definitions for xray-fusion
# Provides consistent error handling across all scripts
# NOTE: This file is sourced. Strict mode is set by the calling script or core::init()

# Source guard: prevent double-sourcing (also prevents readonly redefinition errors)
[[ -n "${_XRF_ERRORS_LOADED:-}" ]] && return 0
readonly _XRF_ERRORS_LOADED=1

# === Success ===
readonly ERR_SUCCESS=0

# === General Errors (1-9) ===
readonly ERR_GENERAL=1     # General failure
readonly ERR_INVALID_ARG=2 # Invalid argument
readonly ERR_NOT_FOUND=3   # Resource not found
readonly ERR_PERMISSION=4  # Permission denied
readonly ERR_CONFIG=5      # Configuration error
readonly ERR_NETWORK=6     # Network error
readonly ERR_TIMEOUT=7     # Operation timeout

# === Special Return Codes (10-19) ===
readonly ERR_HELP_REQUESTED=10 # --help flag (not an error)

# === Validation Errors (20-29) ===
readonly ERR_INVALID_PORT=21    # Port validation failed
readonly ERR_INVALID_UUID=22    # UUID validation failed
readonly ERR_INVALID_SHORTID=23 # shortId validation failed
readonly ERR_INVALID_VERSION=24 # Version validation failed

# === Service Errors (40-49) ===
readonly ERR_SERVICE_START_FAIL=40 # Service failed to start
readonly ERR_SERVICE_STOP_FAIL=41  # Service failed to stop
readonly ERR_SERVICE_NOT_FOUND=42  # Service not found

# === File Operation Errors (50-59) ===
readonly ERR_FILE_NOT_FOUND=50  # File does not exist
readonly ERR_FILE_READ_FAIL=51  # Cannot read file
readonly ERR_FILE_WRITE_FAIL=52 # Cannot write file
readonly ERR_DIR_CREATE_FAIL=53 # Cannot create directory

# === Helper: Get error message ===
# Usage: errors::message <error_code>
# Returns: Human-readable error message
errors::message() {
  local code="${1}"
  case "${code}" in
    "${ERR_SUCCESS}") echo "Success" ;;
    "${ERR_GENERAL}") echo "General failure" ;;
    "${ERR_INVALID_ARG}") echo "Invalid argument" ;;
    "${ERR_NOT_FOUND}") echo "Resource not found" ;;
    "${ERR_PERMISSION}") echo "Permission denied" ;;
    "${ERR_CONFIG}") echo "Configuration error" ;;
    "${ERR_NETWORK}") echo "Network error" ;;
    "${ERR_TIMEOUT}") echo "Operation timeout" ;;
    "${ERR_HELP_REQUESTED}") echo "Help requested" ;;
    "${ERR_INVALID_PORT}") echo "Invalid port" ;;
    "${ERR_INVALID_UUID}") echo "Invalid UUID" ;;
    "${ERR_INVALID_SHORTID}") echo "Invalid shortId" ;;
    "${ERR_INVALID_VERSION}") echo "Invalid version" ;;
    "${ERR_SERVICE_START_FAIL}") echo "Service start failed" ;;
    "${ERR_SERVICE_STOP_FAIL}") echo "Service stop failed" ;;
    "${ERR_SERVICE_NOT_FOUND}") echo "Service not found" ;;
    "${ERR_FILE_NOT_FOUND}") echo "File not found" ;;
    "${ERR_FILE_READ_FAIL}") echo "File read failed" ;;
    "${ERR_FILE_WRITE_FAIL}") echo "File write failed" ;;
    "${ERR_DIR_CREATE_FAIL}") echo "Directory creation failed" ;;
    *) echo "Unknown error (${code})" ;;
  esac
}

# === Helper: Exit with error code and message ===
# Usage: errors::exit <error_code> [custom_message]
# Effect: Logs error and exits with specified code
errors::exit() {
  local code="${1}"
  shift || true
  local msg="${1:-$(errors::message "${code}")}"

  if [[ -n "${msg}" ]]; then
    # Use core::log if available, otherwise fallback to printf
    if declare -F core::log > /dev/null 2>&1; then
      core::log error "${msg}" "$(printf '{"exit_code":%d}' "${code}")"
    else
      printf '[ERROR] %s (exit code: %d)\n' "${msg}" "${code}" >&2
    fi
  fi

  exit "${code}"
}
