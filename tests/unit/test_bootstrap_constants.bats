#!/usr/bin/env bats
# Bootstrap constants validation tests for lib/defaults.sh

load ../test_helper

setup() {
  setup_test_env
}

teardown() {
  cleanup_test_env
}

@test "bootstrap constants - critical defaults are defined" {
  run bash -c '
    set -euo pipefail
    project_root="$1"
    # shellcheck source=lib/defaults.sh
    . "${project_root}/lib/defaults.sh"

    [[ -n "${DEFAULT_XRAY_PORT:-}" ]]
    [[ -n "${DEFAULT_XRAY_FINGERPRINT:-}" ]]
    [[ -n "${DEFAULT_XRAY_LOG_LEVEL:-}" ]]
    [[ -n "${DEFAULT_VERSION:-}" ]]
  ' _ "${PROJECT_ROOT}"

  [ "${status}" -eq 0 ]
}

@test "bootstrap constants - default ports are numeric and in range" {
  run bash -c '
    set -euo pipefail
    project_root="$1"
    # shellcheck source=lib/defaults.sh
    . "${project_root}/lib/defaults.sh"
    [[ "${DEFAULT_XRAY_PORT}" =~ ^[0-9]+$ ]]
    ((DEFAULT_XRAY_PORT > 0 && DEFAULT_XRAY_PORT <= 65535))

    ports=(
      "${DEFAULT_XRAY_PORT}"
    )

    for port in "${ports[@]}"; do
      [[ "${port}" =~ ^[0-9]+$ ]]
      (( port >= 1 && port <= 65535 ))
    done
  ' _ "${PROJECT_ROOT}"

  [ "${status}" -eq 0 ]
}

@test "bootstrap constants - security and feature defaults use valid values" {
  run bash -c '
    set -euo pipefail
    project_root="$1"
    # shellcheck source=lib/defaults.sh
    . "${project_root}/lib/defaults.sh"


    case "${DEFAULT_XRAY_SNIFFING}" in
      true|false) ;;
      *) exit 1 ;;
    esac

    case "${DEFAULT_XRF_DEBUG}" in
      true|false) ;;
      *) exit 1 ;;
    esac

    case "${DEFAULT_XRF_JSON}" in
      true|false) ;;
      *) exit 1 ;;
    esac
  ' _ "${PROJECT_ROOT}"

  [ "${status}" -eq 0 ]
}
