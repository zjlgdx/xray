#!/usr/bin/env bash
# Common test helper functions for xray-fusion tests
# This file is sourced by all test files

# Project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT

# Normalize locale for cross-platform test output stability.
if command -v locale > /dev/null 2>&1 && locale -a 2> /dev/null | grep -q '^C\.UTF-8$'; then
  export LANG="C.UTF-8"
  export LC_ALL="C.UTF-8"
else
  export LANG="C"
  export LC_ALL="C"
fi

# Source core modules for testing
source "${PROJECT_ROOT}/lib/core.sh"
source "${PROJECT_ROOT}/lib/args.sh"

# Compatibility: older bats-core versions do not ship bats_require_minimum_version.
if ! declare -F bats_require_minimum_version > /dev/null 2>&1; then
  bats_require_minimum_version() {
    return 0
  }
fi

# Test fixtures directory
FIXTURES="${PROJECT_ROOT}/tests/fixtures"
export FIXTURES

# Temporary directory for test isolation
setup_test_env() {
  export TEST_TMPDIR="$(mktemp -d -t xray-fusion-test.XXXXXX)"
  # Compatibility: distro-packaged bats may not define BATS_TEST_TMPDIR.
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-${TEST_TMPDIR}}"
  export XRF_PREFIX="${TEST_TMPDIR}/usr/local"
  export XRF_ETC="${TEST_TMPDIR}/etc"
  export XRF_VAR="${TEST_TMPDIR}/var/lib/xray-fusion"

  # Set default values for core environment variables
  export XRF_DEBUG="${XRF_DEBUG:-false}"
  export XRF_JSON="${XRF_JSON:-false}"
}

cleanup_test_env() {
  [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR}" ]] && rm -rf "${TEST_TMPDIR}"
  unset TEST_TMPDIR XRF_PREFIX XRF_ETC XRF_VAR
}

# Assertion helpers
assert_file_exists() {
  local file="${1}"
  [[ -f "${file}" ]] || {
    echo "FAILED: File does not exist: ${file}" >&2
    return 1
  }
}

assert_dir_exists() {
  local dir="${1}"
  [[ -d "${dir}" ]] || {
    echo "FAILED: Directory does not exist: ${dir}" >&2
    return 1
  }
}

assert_equals() {
  local expected="${1}"
  local actual="${2}"
  local msg="${3:-}"
  [[ "${expected}" == "${actual}" ]] || {
    echo "FAILED: Expected '${expected}', got '${actual}'" >&2
    [[ -n "${msg}" ]] && echo "  ${msg}" >&2
    return 1
  }
}

assert_contains() {
  local haystack="${1}"
  local needle="${2}"
  [[ "${haystack}" == *"${needle}"* ]] || {
    echo "FAILED: '${haystack}' does not contain '${needle}'" >&2
    return 1
  }
}

assert_command_success() {
  local cmd="${1}"
  shift
  if ! "${cmd}" "$@"; then
    echo "FAILED: Command failed: ${cmd} $*" >&2
    return 1
  fi
}

assert_command_fails() {
  local cmd="${1}"
  shift
  if "${cmd}" "$@"; then
    echo "FAILED: Command should have failed: ${cmd} $*" >&2
    return 1
  fi
}
