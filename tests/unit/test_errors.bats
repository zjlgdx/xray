#!/usr/bin/env bats
# Test lib/errors.sh - Error handling utilities
# shellcheck disable=SC2154  # Variables defined in test_helper.bash

load ../test_helper

setup() {
  setup_test_env
  source "${PROJECT_ROOT}/lib/core.sh"
  source "${PROJECT_ROOT}/lib/errors.sh"
}

teardown() {
  cleanup_test_env
}

# === errors::message Tests ===

@test "errors::message returns Success for ERR_SUCCESS" {
  result="$(errors::message "${ERR_SUCCESS}")"
  [ "${result}" = "Success" ]
}

@test "errors::message returns General failure for ERR_GENERAL" {
  result="$(errors::message "${ERR_GENERAL}")"
  [ "${result}" = "General failure" ]
}

@test "errors::message returns Invalid argument for ERR_INVALID_ARG" {
  result="$(errors::message "${ERR_INVALID_ARG}")"
  [ "${result}" = "Invalid argument" ]
}

@test "errors::message returns Resource not found for ERR_NOT_FOUND" {
  result="$(errors::message "${ERR_NOT_FOUND}")"
  [ "${result}" = "Resource not found" ]
}

@test "errors::message returns Permission denied for ERR_PERMISSION" {
  result="$(errors::message "${ERR_PERMISSION}")"
  [ "${result}" = "Permission denied" ]
}

@test "errors::message returns Configuration error for ERR_CONFIG" {
  result="$(errors::message "${ERR_CONFIG}")"
  [ "${result}" = "Configuration error" ]
}

@test "errors::message returns Network error for ERR_NETWORK" {
  result="$(errors::message "${ERR_NETWORK}")"
  [ "${result}" = "Network error" ]
}

@test "errors::message returns Operation timeout for ERR_TIMEOUT" {
  result="$(errors::message "${ERR_TIMEOUT}")"
  [ "${result}" = "Operation timeout" ]
}

@test "errors::message returns Help requested for ERR_HELP_REQUESTED" {
  result="$(errors::message "${ERR_HELP_REQUESTED}")"
  [ "${result}" = "Help requested" ]
}

@test "errors::message returns Invalid port for ERR_INVALID_PORT" {
  result="$(errors::message "${ERR_INVALID_PORT}")"
  [ "${result}" = "Invalid port" ]
}

@test "errors::message returns Invalid UUID for ERR_INVALID_UUID" {
  result="$(errors::message "${ERR_INVALID_UUID}")"
  [ "${result}" = "Invalid UUID" ]
}

@test "errors::message returns Invalid shortId for ERR_INVALID_SHORTID" {
  result="$(errors::message "${ERR_INVALID_SHORTID}")"
  [ "${result}" = "Invalid shortId" ]
}

@test "errors::message returns Invalid version for ERR_INVALID_VERSION" {
  result="$(errors::message "${ERR_INVALID_VERSION}")"
  [ "${result}" = "Invalid version" ]
}

@test "errors::message returns Service start failed for ERR_SERVICE_START_FAIL" {
  result="$(errors::message "${ERR_SERVICE_START_FAIL}")"
  [ "${result}" = "Service start failed" ]
}

@test "errors::message returns Service stop failed for ERR_SERVICE_STOP_FAIL" {
  result="$(errors::message "${ERR_SERVICE_STOP_FAIL}")"
  [ "${result}" = "Service stop failed" ]
}

@test "errors::message returns Service not found for ERR_SERVICE_NOT_FOUND" {
  result="$(errors::message "${ERR_SERVICE_NOT_FOUND}")"
  [ "${result}" = "Service not found" ]
}

@test "errors::message returns File not found for ERR_FILE_NOT_FOUND" {
  result="$(errors::message "${ERR_FILE_NOT_FOUND}")"
  [ "${result}" = "File not found" ]
}

@test "errors::message returns File read failed for ERR_FILE_READ_FAIL" {
  result="$(errors::message "${ERR_FILE_READ_FAIL}")"
  [ "${result}" = "File read failed" ]
}

@test "errors::message returns File write failed for ERR_FILE_WRITE_FAIL" {
  result="$(errors::message "${ERR_FILE_WRITE_FAIL}")"
  [ "${result}" = "File write failed" ]
}

@test "errors::message returns Directory creation failed for ERR_DIR_CREATE_FAIL" {
  result="$(errors::message "${ERR_DIR_CREATE_FAIL}")"
  [ "${result}" = "Directory creation failed" ]
}

@test "errors::message returns Unknown error for unknown code" {
  result="$(errors::message 999)"
  [ "${result}" = "Unknown error (999)" ]
}

# === errors::exit Tests ===

@test "errors::exit exits with correct code" {
  run bash -c "source '${PROJECT_ROOT}/lib/core.sh'; source '${PROJECT_ROOT}/lib/errors.sh'; errors::exit 5"
  [ "${status}" -eq 5 ]
}

@test "errors::exit logs error message" {
  run bash -c "source '${PROJECT_ROOT}/lib/core.sh'; source '${PROJECT_ROOT}/lib/errors.sh'; errors::exit ${ERR_CONFIG}" 2>&1
  [ "${status}" -eq 5 ]
  [[ "${output}" == *"Configuration error"* ]] || [[ "${output}" == *"exit_code"* ]]
}

@test "errors::exit uses custom message when provided" {
  run bash -c "source '${PROJECT_ROOT}/lib/core.sh'; source '${PROJECT_ROOT}/lib/errors.sh'; errors::exit ${ERR_GENERAL} 'Custom error message'" 2>&1
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Custom error message"* ]]
}

@test "errors::exit works without core::log loaded" {
  run bash -c "source '${PROJECT_ROOT}/lib/errors.sh'; errors::exit ${ERR_NOT_FOUND}" 2>&1
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"Resource not found"* ]]
}
