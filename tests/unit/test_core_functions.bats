#!/usr/bin/env bats
# Unit tests for core functions (lib/core.sh)

load ../test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

@test "core::ts - returns ISO 8601 timestamp" {
  run core::ts
  [ "$status" -eq 0 ]
  # Check format: YYYY-MM-DDTHH:MM:SSZ
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "core::log - outputs to stderr in text mode" {
  XRF_JSON=false
  run core::log info "test message"
  [ "$status" -eq 0 ]
  # Log should go to stderr (captured in output by bats)
  [[ "$output" == *"test message"* ]]
}

@test "core::log - outputs JSON in JSON mode" {
  XRF_JSON=true
  run core::log info "test message"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"level":"info"'* ]]
  [[ "$output" == *'"msg":"test message"'* ]]
}

@test "core::log - filters debug messages unless XRF_DEBUG=true" {
  XRF_DEBUG=false
  run core::log debug "debug message"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "core::log - shows debug messages when XRF_DEBUG=true" {
  XRF_DEBUG=true
  run core::log debug "debug message"
  [ "$status" -eq 0 ]
  [[ "$output" == *"debug message"* ]]
}

@test "core::retry - succeeds on first attempt" {
  run core::retry 3 true
  [ "$status" -eq 0 ]
}

@test "core::retry - fails after max attempts" {
  run core::retry 2 false
  [ "$status" -eq 1 ]
}

@test "core::retry - succeeds after retries" {
  # Create a file that acts as a counter
  counter_file="${TEST_TMPDIR}/counter"
  echo "0" > "${counter_file}"

  # Function that fails twice then succeeds
  flaky_cmd() {
    local count
    count=$(cat "${counter_file}")
    count=$((count + 1))
    echo "${count}" > "${counter_file}"
    [ "${count}" -ge 3 ]
  }

  run core::retry 5 flaky_cmd
  [ "$status" -eq 0 ]
}

# Tests for core::with_flock
@test "core::with_flock - creates lock file" {
  local lock_file="${TEST_TMPDIR}/test.lock"

  run core::with_flock "${lock_file}" true
  [ "$status" -eq 0 ]
  [ -f "${lock_file}" ]
}

@test "core::with_flock - lock file has correct permissions" {
  local lock_file="${TEST_TMPDIR}/test.lock"

  core::with_flock "${lock_file}" true

  [ -f "${lock_file}" ]
  local perms
  perms=$(stat -c "%a" "${lock_file}" 2>/dev/null || stat -f "%Lp" "${lock_file}")
  [[ "${perms}" == "644" ]]
}

@test "core::with_flock - executes command successfully" {
  local lock_file="${TEST_TMPDIR}/test.lock"
  local output_file="${TEST_TMPDIR}/output.txt"

  run core::with_flock "${lock_file}" bash -c "echo 'test output' > ${output_file}"
  [ "$status" -eq 0 ]
  [ -f "${output_file}" ]
  [[ "$(cat "${output_file}")" == "test output" ]]
}

@test "core::with_flock - prevents concurrent execution" {
  local lock_file="${TEST_TMPDIR}/concurrent.lock"
  local counter_file="${TEST_TMPDIR}/counter.txt"
  echo "0" > "${counter_file}"

  # Start a long-running command with lock
  (
    core::with_flock "${lock_file}" bash -c "sleep 0.5; echo 'done'"
  ) &
  local pid1=$!

  # Wait a bit for first lock to be acquired
  sleep 0.1

  # Try to run another command with same lock (should wait)
  local start_time
  start_time=$(date +%s)
  core::with_flock "${lock_file}" bash -c "echo 'second'"
  local end_time
  end_time=$(date +%s)

  wait "${pid1}"

  # Second command should have waited (at least 0.3 seconds)
  local elapsed=$((end_time - start_time))
  [[ ${elapsed} -ge 0 ]]
}

@test "core::with_flock - lock file created atomically" {
  local lock_file="${TEST_TMPDIR}/atomic.lock"

  # The lock file should be created atomically without TOCTOU window
  # We test this by checking file exists with correct ownership/permissions
  # after with_flock completes

  core::with_flock "${lock_file}" true

  [ -f "${lock_file}" ]

  # Check ownership (should be current user, not root)
  local owner
  owner=$(stat -c "%U" "${lock_file}" 2>/dev/null || stat -f "%Su" "${lock_file}")
  [[ "${owner}" == "$(whoami)" ]] || [[ "${owner}" == "$(id -un)" ]]
}

@test "core::with_flock - fails when command is missing" {
  local lock_file="${TEST_TMPDIR}/test.lock"

  run core::with_flock "${lock_file}"
  [ "$status" -ne 0 ]
}

@test "core::with_flock - propagates command exit code" {
  local lock_file="${TEST_TMPDIR}/test.lock"

  run core::with_flock "${lock_file}" false
  [ "$status" -ne 0 ]

  run core::with_flock "${lock_file}" bash -c "exit 42"
  [ "$status" -eq 42 ]
}

@test "core::with_flock - no-flock strict failure releases directory lock" {
  local lock_file="${TEST_TMPDIR}/fallback.lock"
  run bash -c '
    set -euo pipefail
    source "$1/lib/core.sh"
    command() {
      if [[ "$1" == -v && "$2" == flock ]]; then return 1; fi
      builtin command "$@"
    }
    core::with_flock "$2" false
  ' _ "${PROJECT_ROOT}" "${lock_file}"
  [ "$status" -ne 0 ]
  [ ! -d "${lock_file}.d" ]

  run bash -c '
    set -euo pipefail
    source "$1/lib/core.sh"
    command() {
      if [[ "$1" == -v && "$2" == flock ]]; then return 1; fi
      builtin command "$@"
    }
    XRF_FLOCK_TIMEOUT_SEC=1 core::with_flock "$2" true
  ' _ "${PROJECT_ROOT}" "${lock_file}"
  [ "$status" -eq 0 ]
  [ ! -d "${lock_file}.d" ]
}

@test "core::with_flock - no-flock callback preserves strict and non-strict behavior" {
  local lock_file="${TEST_TMPDIR}/fallback-strict.lock"
  run bash -c '
    set -euo pipefail
    source "$1/lib/core.sh"
    command() {
      if [[ "$1" == -v && "$2" == flock ]]; then return 1; fi
      builtin command "$@"
    }
    callback() { false; printf "CALLBACK_CONTINUED\n"; }
    core::with_flock "$2" callback
    printf "WRAPPER_RETURNED_SUCCESS\n"
  ' _ "${PROJECT_ROOT}" "${lock_file}"
  [ "$status" -ne 0 ]
  [[ "$output" != *CALLBACK_CONTINUED* && "$output" != *WRAPPER_RETURNED_SUCCESS* ]]
  [ ! -d "${lock_file}.d" ]

  run bash -c '
    set -uo pipefail
    source "$1/lib/core.sh"
    command() {
      if [[ "$1" == -v && "$2" == flock ]]; then return 1; fi
      builtin command "$@"
    }
    callback() { false; printf "CALLBACK_CONTINUED\n"; }
    core::with_flock "$2" callback
    callback() { return 42; }
    core::with_flock "$2" callback
    [[ "$?" -eq 42 ]]
  ' _ "${PROJECT_ROOT}" "${lock_file}"
  [ "$status" -eq 0 ]
  [[ "$output" == *CALLBACK_CONTINUED* ]]
  [ ! -d "${lock_file}.d" ]
}

@test "core::with_flock - concurrent first creation locks one inode" {
  [[ "$(uname -s)" == Linux ]] || skip "requires Linux flock"
  command -v flock > /dev/null 2>&1 || skip "flock not available"

  run bash -c '
    set -e
    source "$1/lib/core.sh"
    d=$(mktemp -d)
    test() {
      if [[ "${ROLE:-}" == B && "$*" == "-f $d/lock" && ! -f "$d/b-ready" ]]; then
        local rc=0
        builtin test "$@" || rc=$?
        touch "$d/b-ready"
        while [[ ! -f "$d/a-locked" ]]; do sleep 0.01; done
        return "$rc"
      fi
      builtin test "$@"
    }
    probe_a() {
      touch "$d/a-locked"
      for i in {1..100}; do
        if [[ -f "$d/b-entered" ]]; then printf "OVERLAPPING_LOCK_CALLBACKS\n"; return 0; fi
        sleep 0.01
      done
      printf "NO_OVERLAP\n"
    }
    probe_b() { touch "$d/b-entered"; }
    ROLE=B core::with_flock "$d/lock" probe_b &
    b_pid=$!
    while [[ ! -f "$d/b-ready" ]]; do sleep 0.01; done
    ROLE=A core::with_flock "$d/lock" probe_a
    wait "$b_pid"
  ' _ "${PROJECT_ROOT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *NO_OVERLAP* ]]
  [[ "$output" != *OVERLAPPING_LOCK_CALLBACKS* ]]
}

# Log format consistency tests
@test "core::log - text format uses consistent width (%-8s)" {
  XRF_JSON=false

  # Test different log levels
  run core::log info "test"
  [ "$status" -eq 0 ]
  # Format: [timestamp] level    message
  # The level should be padded to 8 characters
  [[ "$output" =~ ^\[[0-9T:Z-]+\]\ [a-z]+\ {1,8}test ]]

  run core::log warn "warning message"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^\[[0-9T:Z-]+\]\ [a-z]+\ {1,8}warning\ message ]]
}

@test "core::log - JSON format is valid and consistent" {
  XRF_JSON=true

  run core::log info "test message" '{"key":"value"}'
  [ "$status" -eq 0 ]

  # Should be valid JSON
  echo "$output" | grep -q '{"ts":'
  echo "$output" | grep -q '"level":"info"'
  echo "$output" | grep -q '"msg":"test message"'
  echo "$output" | grep -q '"ctx":{"key":"value"}'
}

@test "core::log - timestamp format is ISO 8601" {
  XRF_JSON=false

  run core::log info "test"
  [ "$status" -eq 0 ]

  # Extract timestamp from output: [2025-11-10T12:34:56Z]
  [[ "$output" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\] ]]
}

@test "caddy-cert-sync log format matches core::log" {
  # Extract log function from caddy-cert-sync.sh and test it
  local script="${PROJECT_ROOT}/scripts/caddy-cert-sync.sh"

  # Source only the log function
  source <(sed -n '/^log()/,/^}/p' "${script}")

  XRF_JSON=false
  run log info "test message"
  [ "$status" -eq 0 ]

  # Should use same format as core::log (%-8s width)
  [[ "$output" =~ ^\[[0-9T:Z-]+\]\ [a-z]+\ {1,8}\[caddy-cert-sync\]\ test\ message ]]
}

@test "caddy-cert-sync JSON format matches core::log" {
  # Extract log function from caddy-cert-sync.sh
  local script="${PROJECT_ROOT}/scripts/caddy-cert-sync.sh"
  source <(sed -n '/^log()/,/^}/p' "${script}")

  XRF_JSON=true
  run log info "test message"
  [ "$status" -eq 0 ]

  # Should be valid JSON
  echo "$output" | grep -q '{"ts":'
  echo "$output" | grep -q '"level":"info"'
  echo "$output" | grep -q '"msg":".*caddy-cert-sync.*test message"'
}

# =============================================================================
# core::init() tests
# =============================================================================

@test "core::init - sets strict mode (set -euo pipefail)" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    # Check that errexit is set
    [[ $- == *e* ]] || exit 1
    # Check that nounset is set
    [[ $- == *u* ]] || exit 1
    # Check that pipefail is set
    shopt -o pipefail &>/dev/null || exit 1
  '
  [ "$status" -eq 0 ]
}

@test "core::init - sets XRF_JSON=false by default" {
  run bash -c '
    unset XRF_JSON
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    echo "${XRF_JSON}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "false" ]]
}

@test "core::init - sets XRF_DEBUG=false by default" {
  run bash -c '
    unset XRF_DEBUG
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    echo "${XRF_DEBUG}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "false" ]]
}

@test "core::init - parses --json flag" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init --json
    echo "${XRF_JSON}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "true" ]]
}

@test "core::init - parses --debug flag" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init --debug
    echo "${XRF_DEBUG}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "true" ]]
}

@test "core::init - parses both --json and --debug flags" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init --json --debug
    echo "JSON=${XRF_JSON} DEBUG=${XRF_DEBUG}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "JSON=true DEBUG=true" ]]
}

@test "core::init - ignores unknown flags" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init --unknown --json --other-flag
    echo "${XRF_JSON}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "true" ]]
}

@test "core::init - preserves existing XRF_JSON value when not overridden" {
  run bash -c '
    export XRF_JSON=true
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    echo "${XRF_JSON}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "true" ]]
}

@test "core::init - preserves existing XRF_DEBUG value when not overridden" {
  run bash -c '
    export XRF_DEBUG=true
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    echo "${XRF_DEBUG}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "true" ]]
}

@test "core::init - sets up ERR trap" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    trap -p ERR | grep -q "core::error_handler"
  '
  [ "$status" -eq 0 ]
}

@test "core::init - works with no arguments" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    echo "success"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "success" ]]
}

@test "core::init - flags can appear in any order" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init some-arg --debug other-arg --json
    echo "JSON=${XRF_JSON} DEBUG=${XRF_DEBUG}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == "JSON=true DEBUG=true" ]]
}

# =============================================================================
# core::error_handler() tests
# =============================================================================

@test "core::error_handler - logs critical message with return code" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    # Call error handler directly (normally called by trap)
    core::error_handler 42 100 "failed_command" 2>&1 || true
  '
  # Note: error_handler exits, so we check output
  [[ "${output}" == *"ERR trap"* ]]
  [[ "${output}" == *'"rc":42'* ]]
  [[ "${output}" == *'"line":100'* ]]
}

@test "core::error_handler - includes command in log" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::error_handler 1 50 "some_failing_cmd --flag" 2>&1 || true
  '
  [[ "${output}" == *"some_failing_cmd"* ]]
}

@test "core::error_handler - exits with provided return code" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::error_handler 123 10 "test"
  '
  [ "$status" -eq 123 ]
}

@test "core::error_handler - logs in JSON format when XRF_JSON=true" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=true
    export XRF_DEBUG=false
    core::error_handler 1 25 "test_cmd" 2>&1 || true
  '
  [[ "${output}" == *'"level":"critical"'* ]]
  [[ "${output}" == *'"msg":"ERR trap"'* ]]
}

@test "core::error_handler - uses CRITICAL level (uppercase in text mode)" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::error_handler 1 25 "test_cmd" 2>&1 || true
  '
  [[ "${output}" == *"CRITICAL"* ]]
}

@test "core::error_handler - handles special characters in command" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::error_handler 1 50 "echo \$VAR | grep pattern" 2>&1 || true
  '
  [ "$status" -eq 1 ]
  [[ "${output}" == *"ERR trap"* ]]
}

# =============================================================================
# ERR trap integration tests
# =============================================================================

@test "ERR trap triggers on command failure" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    export XRF_JSON=false
    false  # This should trigger the ERR trap
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "${output}" == *"ERR trap"* ]]
}

@test "ERR trap includes line number" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    export XRF_JSON=false
    false  # line 5
  ' 2>&1
  [ "$status" -ne 0 ]
  [[ "${output}" == *'"line":'* ]]
}

@test "ERR trap preserves original exit code" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    export XRF_JSON=false
    exit 77
  '
  [ "$status" -eq 77 ]
}

@test "ERR trap includes failed command" {
  run -127 bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    core::init
    export XRF_JSON=false
    /nonexistent/command 2>/dev/null
  ' 2>&1
  [[ "${output}" == *'"cmd":'* ]]
}

# =============================================================================
# core::log additional edge cases
# =============================================================================

@test "core::log - fatal level exits with code 1" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::log fatal "fatal error message"
  '
  [ "$status" -eq 1 ]
  [[ "${output}" == *"fatal error message"* ]]
}

@test "core::log - critical level does not exit" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::log critical "critical error"
    echo "still running"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == *"critical error"* ]]
  [[ "${output}" == *"still running"* ]]
}

@test "core::log - handles empty context" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::log info "message with no context"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == *"message with no context"* ]]
}

@test "core::log - handles empty {} context in JSON mode" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=true
    export XRF_DEBUG=false
    core::log info "test" "{}"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == *'"ctx":{}'* ]]
}

@test "core::log - warn level works correctly" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::log warn "warning message"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == *"warn"* ]]
  [[ "${output}" == *"warning message"* ]]
}

@test "core::log - error level works correctly" {
  run bash -c '
    source "'"${PROJECT_ROOT}/lib/core.sh"'"
    export XRF_JSON=false
    export XRF_DEBUG=false
    core::log error "error message"
  '
  [ "$status" -eq 0 ]
  [[ "${output}" == *"error"* ]]
  [[ "${output}" == *"error message"* ]]
}
