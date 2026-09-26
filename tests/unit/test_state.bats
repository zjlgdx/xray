#!/usr/bin/env bats
# Unit tests for state management module (modules/state.sh)

load ../test_helper

setup() {
  setup_test_env
  # Source state module
  source "${PROJECT_ROOT}/modules/state.sh" 2>/dev/null || true

  # Override state directory for testing
  export XRF_VAR="${TEST_TMPDIR}/var"
}

teardown() {
  cleanup_test_env
}

# state::dir tests
@test "state::dir - returns default directory" {
  unset XRF_VAR
  run state::dir
  [ "$status" -eq 0 ]
  [[ "${output}" == "/var/lib/xray-fusion" ]]
}

@test "state::dir - respects XRF_VAR override" {
  export XRF_VAR="/custom/path"
  run state::dir
  [ "$status" -eq 0 ]
  [[ "${output}" == "/custom/path" ]]
}

# state::path tests
@test "state::path - returns state file path" {
  run state::path
  [ "$status" -eq 0 ]
  [[ "${output}" == "${XRF_VAR}/state.json" ]]
}

# state::digest tests
@test "state::digest - returns digest file path" {
  run state::digest
  [ "$status" -eq 0 ]
  [[ "${output}" == "${XRF_VAR}/config.sha256" ]]
}

# state::lock tests
@test "state::lock - returns lock file path" {
  run state::lock
  [ "$status" -eq 0 ]
  [[ "${output}" == "${XRF_VAR}/locks/configure.lock" ]]
}

# state::save tests
@test "state::save - creates state directory" {
  local test_json='{"version":"1.0","installed":true}'

  run state::save "${test_json}"
  [ "$status" -eq 0 ]
  [ -d "${XRF_VAR}" ]
}

@test "state::save - writes JSON to state file" {
  local test_json='{"version":"1.0","installed":true}'

  state::save "${test_json}"

  [ -f "$(state::path)" ]
  local content
  content="$(cat "$(state::path)")"
  [[ "${content}" == "${test_json}" ]]
}

@test "state::save - overwrites existing state" {
  local first_json='{"version":"1.0"}'
  local second_json='{"version":"2.0"}'

  state::save "${first_json}"
  state::save "${second_json}"

  local content
  content="$(cat "$(state::path)")"
  [[ "${content}" == "${second_json}" ]]
}

@test "state::save - creates file with correct permissions" {
  local test_json='{}'

  state::save "${test_json}"

  [ -f "$(state::path)" ]
  local perms
  perms=$(stat -c "%a" "$(state::path)" 2>/dev/null || stat -f "%Lp" "$(state::path)")
  [[ "${perms}" == "600" ]]
  perms=$(stat -c "%a" "$(state::dir)" 2>/dev/null || stat -f "%Lp" "$(state::dir)")
  [[ "${perms}" == "700" ]]
}

@test "state::save - handles multiline JSON" {
  local test_json='{"version":"1.0","data":{"key1":"value1","key2":"value2"}}'

  state::save "${test_json}"

  local content
  content="$(cat "$(state::path)")"
  [[ "${content}" == "${test_json}" ]]
}

@test "state::save - handles empty JSON object" {
  local test_json='{}'

  run state::save "${test_json}"
  [ "$status" -eq 0 ]

  local content
  content="$(cat "$(state::path)")"
  [[ "${content}" == "{}" ]]
}

# state::load tests
@test "state::load - returns empty object when file doesn't exist" {
  # Ensure state file doesn't exist
  rm -f "$(state::path)"

  run state::load
  [ "$status" -eq 0 ]
  [[ "${output}" == "{}" ]]
}

@test "state::load - reads existing state file" {
  local test_json='{"version":"1.0","installed":true}'

  mkdir -p "${XRF_VAR}"
  echo "${test_json}" > "$(state::path)"

  run state::load
  [ "$status" -eq 0 ]
  [[ "${output}" == "${test_json}" ]]
}

@test "state::load - reads multiline JSON" {
  local test_json='{"version":"1.0","data":{"key1":"value1","key2":"value2"}}'

  mkdir -p "${XRF_VAR}"
  echo "${test_json}" > "$(state::path)"

  run state::load
  [ "$status" -eq 0 ]
  [[ "${output}" == "${test_json}" ]]
}

# Integration tests
@test "state::save and state::load - round trip" {
  local test_json='{"version":"1.0","topology":"reality-only","uuid":"test-uuid-123"}'

  state::save "${test_json}"

  local loaded
  loaded="$(state::load)"
  [[ "${loaded}" == "${test_json}" ]]
}

@test "state::save - creates nested directory structure" {
  local test_json='{}'

  # State module should create parent directories
  run state::save "${test_json}"
  [ "$status" -eq 0 ]
  [ -d "${XRF_VAR}" ]
  [ -f "$(state::path)" ]
}

@test "state::lock - directory structure" {
  # The lock path includes a 'locks' subdirectory
  local lock_path
  lock_path="$(state::lock)"

  [[ "${lock_path}" == *"/locks/configure.lock" ]]
}

@test "state::path - multiple calls return same value" {
  local path1 path2
  path1="$(state::path)"
  path2="$(state::path)"

  [[ "${path1}" == "${path2}" ]]
}

@test "state::save - atomic write behavior" {
  local test_json='{"test":"atomic"}'

  # Save should use io::atomic_write which is atomic
  state::save "${test_json}"

  # File should exist completely (not partial)
  [ -f "$(state::path)" ]
  local content
  content="$(cat "$(state::path)")"
  [[ "${content}" == "${test_json}" ]]
}
